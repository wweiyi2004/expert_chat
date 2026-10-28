import 'host_backend.dart';
import 'operation_ledger.dart';
import 'migration_backup.dart';
import 'legacy_instance_guard.dart';
import '../../features/tui_bridge/gui_actions_host.dart';
import '../../platform/web_auth_host.dart' as auth;
import 'dart:math';
// Both endpoints ship Drift 2.33.0; compatibility is checked by transport tests.
// ignore: experimental_member_use
import 'package:drift/remote.dart';
import 'package:stream_channel/stream_channel.dart';
import '../../platform/database_open.dart';
import '../../platform/atomic_file.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';
import '../../core/providers.dart';
import '../../core/desktop_providers.dart';
import '../../platform/paths_host.dart';
import '../../platform/preferences.dart';
import '../../platform/credentials_host.dart' as host_credentials;
import '../../data/backup_journal.dart';
import '../../data/full_backup_service.dart';
import '../../data/library_file_store.dart';
import '../../data/memory_file_store.dart';
import '../../data/db/app_database.dart';
import '../../data/drift_conversation_repository.dart';
import '../../data/legacy_conversation_migration.dart';
import '../../data/study_repository.dart';
import '../../features/tui_bridge/discovery.dart';
import '../../features/tui_bridge/server.dart';
import '../../state/chat_controller.dart';
import '../../state/settings_controller.dart';
import '../desktop/workspace_host_io.dart';

/// Owns all task services without a Flutter engine, widget tree or GUI process.
class DesktopHost {
  static DesktopHost? _active;
  DesktopHost({
    this.dataDirectory,
    this.discoveryDirectory,
    this.workspaceExecutable,
    this.guiClientPid,
    this.idleTimeout = const Duration(minutes: 10),
  });
  final String? dataDirectory, discoveryDirectory, workspaceExecutable;
  final int? guiClientPid;
  final Duration idleTimeout;
  Timer? _idleTimer;
  DateTime? _idleSince;
  RandomAccessFile? _ownerLock;
  ProviderContainer? _container;
  AppDatabase? _database;
  DriftServer? _databaseServer;
  DesktopHostBackend? _backend;
  HostOperationLedger? _operations;
  File? _guiDiscovery;
  TuiBridgeServer? _bridge;
  final _done = Completer<void>();
  bool _closing = false;
  final _legacyGuard = LegacyInstanceGuard();
  Future<void> get done => _done.future;
  int? get port => _bridge?.port;

  Future<void> start() async {
    if (_active != null) throw StateError('同一进程只能持有一个执行宿主');
    _active = this;
    try {
      if (dataDirectory != null) {
        HostPaths.stateDirectory = p.absolute(dataDirectory!);
      }
      final directory = await getApplicationSupportDirectory();
      final control = Directory(p.join(directory.path, 'host'));
      final discovery = BridgeDiscovery(
        Directory(
          discoveryDirectory ??
              (dataDirectory == null
                  ? BridgeDiscovery.defaultDirectory().path
                  : p.join(control.path, 'discovery')),
        ),
      );
      await control.create(recursive: true);
      _ownerLock = await File(
        p.join(control.path, 'owner.lock'),
      ).open(mode: FileMode.append);
      await _ownerLock!.lock(FileLock.exclusive);
      if (dataDirectory == null) _legacyGuard.acquire();
      await preservePreHostData();
      if (await discovery.file.exists()) {
        try {
          final previous =
              jsonDecode(await discovery.file.readAsString()) as Map;
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            previous['port'] as int,
            timeout: const Duration(milliseconds: 400),
          );
          socket.destroy();
          throw StateError('已有后台正在使用桥接。请结束旧任务并退出旧后台后启动新版。');
        } on SocketException {
          /* A stale discovery file is replaced by the owner. */
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await const host_credentials.FlutterSecureStorage().migrateLegacy();
      final dbServer = _databaseServer = DriftServer(openAppDatabase());
      final local = StreamChannelController<Object?>(sync: true);
      unawaited(dbServer.serve(local.local));
      final connection = await connectToRemoteAndInitialize(local.foreign);
      final db = _database = AppDatabase(connection);
      await FullBackupService(
        db,
        LibraryFileStore(),
        MemoryFileStore(prefs),
        prefs,
        BackupJournal(),
      ).recoverPending();
      final repo = DriftConversationRepository(db);
      await migrateLegacyJsonToDrift(repo);
      await StudyRepository(db, prefs).ensureMigrated();
      final container = _container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          desktopWorkspaceHostProvider.overrideWithValue(
            CliDesktopWorkspaceHost(
              executable:
                  workspaceExecutable ??
                  p.join(HostPaths.bundleDirectory, 'expert-desktop.exe'),
              dataDirectory: dataDirectory == null
                  ? null
                  : p.join(directory.path, 'workspace-state'),
            ),
          ),
        ],
      );
      await container.read(settingsControllerProvider.future);
      await container.read(chatControllerProvider.future);
      final operations = _operations = await HostOperationLedger.open(
        File(p.join(control.path, 'operations.jsonl')),
      );
      final backend = _backend = DesktopHostBackend(
        container,
        requestShutdown: close,
        databaseServer: dbServer,
        operationLedger: operations,
        guiEnvironment: {
          'EXPERT_HOST_DISCOVERY': discovery.directory.path,
          'EXPERT_CHAT_HOST': Platform.resolvedExecutable,
          if (HostPaths.stateDirectory != null)
            'EXPERT_HOST_DATA_DIR': HostPaths.stateDirectory!,
        },
      );
      hostGuiNavigator = backend.navigateGui;
      auth.FlutterWebAuth2.clientAuthorize = (url, scheme, options) =>
          backend.authorizeInGui(url, scheme, {
            'useWebview': options.useWebview,
            'timeout': options.timeout,
            'httpsHost': options.httpsHost,
            'httpsPath': options.httpsPath,
          });
      final random = Random.secure();
      final guiToken = base64UrlEncode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      _bridge = TuiBridgeServer(
        backend: backend,
        discovery: discovery,
        privilegedToken: guiToken,
      );
      await _bridge!.start();
      final guiFile = _guiDiscovery = File(
        p.join(discovery.directory.path, 'gui.json'),
      );
      await writeAtomic(
        guiFile,
        utf8.encode(jsonEncode({'pid': pid, 'token': guiToken, 'v': 1})),
      );
      if (idleTimeout > Duration.zero) {
        _idleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          if (_closing) return;
          if (_bridge!.clientCount > 0 || !backend.idle) {
            _idleSince = null;
            return;
          }
          _idleSince ??= DateTime.now();
          if (DateTime.now().difference(_idleSince!) >= idleTimeout) {
            unawaited(close());
          }
        });
      }
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _idleTimer?.cancel();
    var failed = false;
    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        failed = true;
      }
    }

    await attempt(() async => await _backend?.drain());
    await attempt(() async => await _bridge?.stop());
    await attempt(() async => await _backend?.databaseHub.close());
    await attempt(() => _backend?.disposeProjection());
    await attempt(() async => await _operations?.close());
    await attempt(() => _container?.dispose());
    await attempt(() async => await _database?.close());
    await attempt(() async => await _databaseServer?.shutdown());
    await attempt(() async {
      if (_guiDiscovery case final file?) {
        if (await file.exists()) await file.delete();
      }
    });
    final lock = _ownerLock;
    _ownerLock = null;
    if (lock != null) {
      await attempt(() async {
        await lock.close();
      });
    }
    _legacyGuard.close();
    if (identical(_active, this)) _active = null;
    HostPaths.stateDirectory = null;
    hostGuiNavigator = null;
    auth.FlutterWebAuth2.clientAuthorize = null;
    if (!_done.isCompleted) _done.complete();
    if (failed) {
      stderr.writeln(
        'Host shutdown encountered a persistence or cleanup failure; recovery records were retained.',
      );
    }
  }
}
