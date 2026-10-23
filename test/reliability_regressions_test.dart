import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/backup_journal.dart';
import 'package:expert_chat/data/backup_codec.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/full_backup_service.dart';
import 'package:expert_chat/data/learning_plan.dart';
import 'package:expert_chat/data/library_file_store.dart';
import 'package:expert_chat/data/memory_repository.dart';
import 'package:expert_chat/data/study_models.dart';
import 'package:expert_chat/data/research/ssh_profile.dart';
import 'package:expert_chat/domain/research/research_ssh_client_io.dart';
import 'package:expert_chat/domain/research/research_files_io.dart';
import 'package:expert_chat/domain/research/research_files.dart';
import 'package:expert_chat/state/learning_plan_controller.dart';
import 'package:expert_chat/state/study_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages - test-only transitive platform dep
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

LearningPlan fixture(String id) => LearningPlan(
  id: id,
  topic: 'math',
  goal: 'exam',
  deadline: '2026-12-01',
  dailyMinutes: 30,
  foundation: true,
  material: 'notes',
  schedule: 'schedule',
  knowledge: const [
    LearningKnowledge(
      id: 'K1',
      title: 'addition',
      criterion: 'solve',
      source: 'notes',
    ),
  ],
);
String encodePlans(List<LearningPlan> plans) =>
    jsonEncode(plans.map((p) => p.toJson()).toList());

class Memory implements MemoryStore {
  String value = '';
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String markdown) async {
    value = markdown;
  }

  @override
  Future<String> locationLabel() async => 'test';
}

class Tutor extends StudyController {
  int calls = 0;
  @override
  Future<StudyLibrary> build() async => StudyLibrary.empty;
  @override
  Future<String> completeText({
    required String system,
    required String user,
    CancelToken? cancelToken,
  }) async {
    calls++;
    return 'lesson content';
  }
}

class FailingStore extends SharedPreferencesStorePlatform {
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
  @override
  Future<Map<String, Object>> getAll() async => {};
  @override
  Future<bool> clear() async => true;
  @override
  Future<bool> remove(String key) async => true;
}

class ControlledStore extends SharedPreferencesStorePlatform {
  ControlledStore(this.values);
  final Map<String, Object> values;
  final firstWrite = Completer<void>();
  final release = Completer<void>();
  int writes = 0;
  bool failFirst = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (++writes == 1) {
      firstWrite.complete();
      await release.future;
      if (failFirst) throw StateError('synthetic disk failure');
    }
    values[key] = value;
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }
}

class DownloadClient implements SSHClient {
  DownloadClient({this.readGate});
  final Completer<void>? readGate;
  final opened = Completer<void>();
  @override
  Future<SftpClient> sftp() async {
    if (!opened.isCompleted) opened.complete();
    return DownloadChannel(readGate);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DownloadChannel implements SftpClient {
  DownloadChannel(this.readGate);
  final Completer<void>? readGate;
  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      SftpFileAttrs(size: 4);
  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async => DownloadFile(readGate);
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DownloadFile implements SftpFile {
  DownloadFile(this.readGate);
  final Completer<void>? readGate;
  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int)? onProgress,
    int chunkSize = 32768,
    int maxPendingRequests = 64,
  }) async* {
    if (readGate != null) await readGate!.future;
    yield Uint8List.fromList(utf8.encode('data'));
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<
  ({
    FullBackupService service,
    SharedPreferences prefs,
    AppDatabase db,
    BackupJournal journal,
  })
>
backupHarness() async {
  SharedPreferences.setMockInitialValues({
    learningPlansKey: encodePlans([fixture('backup')]),
  });
  final prefs = await SharedPreferences.getInstance();
  final db = AppDatabase(NativeDatabase.memory());
  final temp = await Directory.systemTemp.createTemp('expert-learning-backup-');
  addTearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  final journal = BackupJournal(pathOverride: '${temp.path}/journal.json');
  final service = FullBackupService(
    db,
    LibraryFileStore(rootOverride: '${temp.path}/library'),
    Memory(),
    prefs,
    journal,
  );
  return (service: service, prefs: prefs, db: db, journal: journal);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final restorePrefs in [false, true]) {
    test(
      'backup imports learning data and preserves current plans, restorePreferences=$restorePrefs',
      () async {
        SharedPreferences.setMockInitialValues({
          learningPlansKey: encodePlans([
            fixture('backup-plan').withLessons([
              const LearningLesson(
                date: '2026-10-22',
                knowledgeIds: ['K1'],
                content: 'lesson',
                feedback: [
                  LearningFeedback(
                    answer: '2',
                    assessment: 'correct',
                    date: '2026-10-22',
                    passed: ['K1'],
                  ),
                ],
              ),
            ]),
          ]),
          'themeMode': 1,
        });
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase(NativeDatabase.memory());
        final temp = await Directory.systemTemp.createTemp('expert-review-');
        addTearDown(() async {
          await db.close();
          await temp.delete(recursive: true);
        });
        final service = FullBackupService(
          db,
          LibraryFileStore(rootOverride: '${temp.path}/library'),
          Memory(),
          prefs,
          BackupJournal(pathOverride: '${temp.path}/journal.json'),
        );
        final preview = await service.preview(await service.exportBackup());
        expect(preview.learningPlans, 1);
        await prefs.setString(
          learningPlansKey,
          encodePlans([fixture('current-plan')]),
        );
        await prefs.setInt('themeMode', 2);
        await service.restoreCopies(preview, restorePreferences: restorePrefs);
        final result = jsonDecode(prefs.getString(learningPlansKey)!) as List;
        expect(
          result.map((p) => p['topic']).length,
          2,
          reason:
              'Import as copies must retain current learning data and restore the backup learning data',
        );
        expect(result.first, fixture('current-plan').toJson());
        expect(result.last['id'], isNot('backup-plan'));
        expect(result.last['id'], isNot('current-plan'));
        expect(LearningPlan.fromJson(result.last).evidence, {'K1': true});
        expect(prefs.getInt('themeMode'), restorePrefs ? 1 : 2);
        await service.restoreCopies(preview, restorePreferences: restorePrefs);
        final repeated = jsonDecode(prefs.getString(learningPlansKey)!) as List;
        expect(repeated.map((p) => p['id']).toSet(), hasLength(3));
      },
    );
  }

  test('old backups without learning plans preserve current plans', () async {
    final h = await backupHarness();
    final payload = BackupCodec.decode(await h.service.exportBackup());
    (payload['preferences'] as Map).remove(learningPlansKey);
    final before = h.prefs.getString(learningPlansKey);
    await h.service.restoreCopies(
      await h.service.preview(BackupCodec.encode(payload)),
      restorePreferences: true,
    );
    expect(h.prefs.getString(learningPlansKey), before);
  });

  test('invalid learning data is rejected before writes', () async {
    final h = await backupHarness();
    final payload = BackupCodec.decode(await h.service.exportBackup());
    final before = h.prefs.getString(learningPlansKey);
    payload['preferences'][learningPlansKey] = '[{"id":"broken"}]';
    await expectLater(
      h.service.preview(BackupCodec.encode(payload)),
      throwsFormatException,
    );
    expect(h.prefs.getString(learningPlansKey), before);
    expect(await h.journal.read(), isNull);
    final preview = await h.service.preview(await h.service.exportBackup());
    await h.prefs.setString(learningPlansKey, 'broken current data');
    await expectLater(h.service.restoreCopies(preview), throwsFormatException);
    expect(h.prefs.getString(learningPlansKey), 'broken current data');
    expect(await h.journal.read(), isNull);
  });

  test('failed restore commit rolls learning plans back', () async {
    final h = await backupHarness();
    final preview = await h.service.preview(await h.service.exportBackup());
    final before = encodePlans([fixture('current')]);
    await h.prefs.setString(learningPlansKey, before);
    await h.db.customStatement(
      "CREATE TRIGGER fail_restore BEFORE INSERT ON backup_imports BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
    );
    await expectLater(h.service.restoreCopies(preview), throwsA(anything));
    await h.prefs.reload();
    expect(h.prefs.getString(learningPlansKey), before);
    expect(await h.journal.read(), isNull);
  });

  for (final failFirst in [false, true]) {
    test(
      'concurrent lesson writes use last committed state, failFirst=$failFirst',
      () async {
        final raw = encodePlans([fixture('a'), fixture('b')]);
        SharedPreferences.setMockInitialValues({learningPlansKey: raw});
        final prefs = await SharedPreferences.getInstance();
        final original = SharedPreferencesStorePlatform.instance;
        addTearDown(() => SharedPreferencesStorePlatform.instance = original);
        final store = ControlledStore({'flutter.$learningPlansKey': raw})
          ..failFirst = failFirst;
        SharedPreferencesStorePlatform.instance = store;
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            studyControllerProvider.overrideWith(Tutor.new),
          ],
        );
        addTearDown(container.dispose);
        final ctrl = container.read(learningPlanControllerProvider.notifier);
        final first = ctrl.startToday('a', now: DateTime(2026, 10, 22));
        final checkedFirst = expectLater(
          first,
          failFirst ? throwsStateError : completes,
        );
        await store.firstWrite.future;
        expect(ctrl.plan('a').lessons, isEmpty);
        final second = ctrl.startToday('b', now: DateTime(2026, 10, 22));
        await Future<void>.delayed(Duration.zero);
        store.release.complete();
        await checkedFirst;
        await second;
        await prefs.reload();
        final persisted =
            (jsonDecode(prefs.getString(learningPlansKey)!) as List)
                .map((p) => LearningPlan.fromJson(p))
                .toList();
        expect(persisted[0].lessons, hasLength(failFirst ? 0 : 1));
        expect(persisted[1].lessons, hasLength(1));
        expect(ctrl.plan('a').lessons, hasLength(failFirst ? 0 : 1));
        expect(container.read(learningBusyProvider), isEmpty);
      },
    );
  }

  test('failed lesson save must remain retryable', () async {
    SharedPreferences.setMockInitialValues({
      learningPlansKey: encodePlans([fixture('p')]),
    });
    final prefs = await SharedPreferences.getInstance();
    final tutor = Tutor();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        studyControllerProvider.overrideWith(() => tutor),
      ],
    );
    addTearDown(container.dispose);
    final ctrl = container.read(learningPlanControllerProvider.notifier);
    final originalStore = SharedPreferencesStorePlatform.instance;
    addTearDown(() => SharedPreferencesStorePlatform.instance = originalStore);
    SharedPreferencesStorePlatform.instance = FailingStore();
    await expectLater(
      ctrl.startToday('p', now: DateTime(2026, 10, 22)),
      throwsStateError,
    );
    expect(ctrl.plan('p').lessons, isEmpty);
    SharedPreferencesStorePlatform.instance = originalStore;
    await ctrl.startToday('p', now: DateTime(2026, 10, 22));
    await prefs.reload();
    final persisted = LearningPlan.fromJson(
      (jsonDecode(prefs.getString(learningPlansKey)!) as List).single
          as Map<String, dynamic>,
    );
    expect(
      persisted.lessons,
      hasLength(1),
      reason:
          'A successful retry must persist the lesson, not silently return based on unsaved state',
    );
  });

  test(
    'downloading a file must preserve an unrelated sibling named .part',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'expert-review-download-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final target = '${temp.path}/report.txt';
      final sibling = File('$target.part');
      await sibling.writeAsString('existing user data');
      await SshResearchFiles(DownloadClient()).download(
        '/report.txt',
        target,
        token: ResearchTransferToken(),
        progress: (_, _) {},
      );
      expect(await File(target).readAsString(), 'data');
      expect(
        await sibling.exists(),
        true,
        reason:
            'The user selected report.txt, not report.txt.part; sibling data must not be truncated or removed',
      );
      expect(await sibling.readAsString(), 'existing user data');
      expect(
        await temp.list().length,
        2,
        reason: 'Owned staging directory is removed',
      );
    },
  );

  test(
    'SSH server that accepts TCP but sends no handshake must time out',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen(sockets.add);
      final client = ResearchSshClientIo();
      final connecting = client.connect(
        profile: SshProfile(
          id: 'probe',
          name: 'probe',
          host: '127.0.0.1',
          port: server.port,
          username: 'probe',
        ),
        password: null,
        privateKeyPem: null,
        passphrase: null,
        onHostKeyTrust: (_) async => true,
        onHostKeyMismatch: (_, _) async => false,
        connectTimeout: const Duration(milliseconds: 100),
      );
      try {
        await expectLater(
          connecting.timeout(const Duration(seconds: 1)),
          throwsA(
            isA<ResearchSshException>().having(
              (e) => e.message,
              'message',
              'SSH 握手超时',
            ),
          ),
          reason:
              'The configured SSH timeout should end connect; an outer test timeout means it is stuck',
        );
      } finally {
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        try {
          await connecting.timeout(const Duration(seconds: 1));
        } catch (_) {}
        await client.disconnect();
      }
    },
  );

  test('cancelled download preserves target and releases its lock', () async {
    final temp = await Directory.systemTemp.createTemp(
      'expert-download-cancel-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final target = '${temp.path}/report.txt';
    await File(target).writeAsString('old');
    final gate = Completer<void>();
    final client = DownloadClient(readGate: gate);
    final token = ResearchTransferToken();
    final first = SshResearchFiles(
      client,
    ).download('/a', target, token: token, progress: (_, _) {});
    final cancelled = expectLater(first, throwsStateError);
    await client.opened.future;
    await expectLater(
      SshResearchFiles(DownloadClient()).download(
        '/b',
        '${temp.path}/./report.txt',
        token: ResearchTransferToken(),
        progress: (_, _) {},
      ),
      throwsStateError,
    );
    token.cancelled = true;
    gate.complete();
    await cancelled;
    expect(await File(target).readAsString(), 'old');
    expect(await temp.list().length, 1);
    await SshResearchFiles(DownloadClient()).download(
      '/b',
      target,
      token: ResearchTransferToken(),
      progress: (_, _) {},
    );
    expect(await File(target).readAsString(), 'data');
    expect(await temp.list().length, 1);
  });

  test('disconnect closes SSH while waiting for handshake', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>();
    final closed = Completer<void>();
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (_) {
          if (!accepted.isCompleted) accepted.complete();
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
    final client = ResearchSshClientIo();
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
      await client.disconnect();
    });
    final connecting = client.connect(
      profile: SshProfile(
        id: 'cancel',
        name: 'cancel',
        host: '127.0.0.1',
        port: server.port,
        username: 'probe',
      ),
      password: null,
      privateKeyPem: null,
      passphrase: null,
      onHostKeyTrust: (_) async => true,
      onHostKeyMismatch: (_, _) async => false,
      connectTimeout: const Duration(seconds: 10),
    );
    final failed = expectLater(
      connecting.timeout(const Duration(seconds: 3)),
      throwsA(isA<ResearchSshException>()),
    );
    await accepted.future.timeout(const Duration(seconds: 2));
    await client.disconnect();
    await failed;
    await closed.future.timeout(const Duration(seconds: 2));
    expect(client.isConnected, false);
  });
}
