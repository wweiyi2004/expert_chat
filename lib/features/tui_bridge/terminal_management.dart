import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/providers.dart';
import '../../data/library_models.dart';
import '../../data/research/ssh_profile.dart';
import '../../domain/research/research_ssh_contract.dart';
import '../../domain/tools/attachment_ingestor.dart';
import '../../state/chat_controller.dart';
import '../../state/research_terminal_controller.dart';
import '../../state/session_policy.dart';
import 'protocol.dart';

class _SshLogin {
  _SshLogin(this.id, this.scope, this.profile);
  final String id, scope, profile;
  bool done = false;
  bool cancelled = false;
  Map<String, Object?>? challenge;
  Completer<bool>? decision;
  Completer<void> changed = Completer<void>();
  void notify() {
    if (!changed.isCompleted) changed.complete();
  }
}

/// Native terminal management. All records returned here are public metadata;
/// passwords and private keys only pass into the existing secure store.
class TuiManagementService {
  TuiManagementService(this.container, {required this.rememberSecrets});
  final ProviderContainer container;
  final void Function(Iterable<String>) rememberSecrets;
  _SshLogin? _login;
  ResearchTerminalController get ssh =>
      container.read(researchTerminalProvider.notifier);
  ResearchTerminalState get sshState =>
      container.read(researchTerminalProvider);
  ChatController get chat => container.read(chatControllerProvider.notifier);
  String version(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  bool handles(String method, Map<String, dynamic> args) {
    if (method != 'terminal.query' && method != 'terminal.action') return false;
    final topic = args[method == 'terminal.query' ? 'topic' : 'action'];
    return topic is String &&
        (topic.startsWith('ssh.') || topic.startsWith('library.manage'));
  }

  Map<String, Object?> page(String view, Map<String, Object?> data) => {
    'management': view,
    ...data,
  };
  void idle() {
    if (chat.runningConversationIds.isNotEmpty) {
      throw const BridgeFailure('busy', '有任务正在运行；请任务结束后再改变共享 SSH 连接或资料绑定');
    }
  }

  void confirmed(Map<String, dynamic> a) {
    if (a['confirmed'] != true) {
      throw const BridgeFailure('confirmation_required', '请确认此操作');
    }
  }

  SshProfile profile(String id) =>
      sshState.profiles.where((v) => v.id == id).firstOrNull ??
      (throw const BridgeFailure('not_found', 'SSH 配置已不存在'));
  void connection(Map<String, dynamic> a) {
    if (!sshState.isConnected ||
        a['profile'] != sshState.activeProfileId ||
        a['generation'] != sshState.connectionGeneration) {
      throw const BridgeFailure('stale_connection', 'SSH 连接已变化，请返回 SSH 列表重新打开');
    }
  }

  Map<String, Object?> sshList() => page('ssh_list', {
    'profiles': [
      for (final v in sshState.profiles)
        {
          ...v.toJson(),
          'version': version(v.toJson()),
          'connected': sshState.isConnected && sshState.activeProfileId == v.id,
        },
    ],
    'profile': sshState.activeProfileId,
    'generation': sshState.connectionGeneration,
    'status': sshState.statusMessage,
  });
  Map<String, Object?> sshProfile(SshProfile value) => page('ssh_profile', {
    ...value.toJson(),
    'remote_forward': value.remoteForwardText,
    'version': version(value.toJson()),
    'connected': sshState.isConnected && sshState.activeProfileId == value.id,
    'profile': value.id,
    'generation': sshState.connectionGeneration,
    'status': sshState.activeProfileId == value.id
        ? sshState.statusMessage
        : '',
  });
  void release(String scope) {
    final job = _login;
    if (job == null || job.scope != scope || job.done) return;
    job.cancelled = true;
    if (job.decision?.isCompleted == false) job.decision!.complete(false);
    if (sshState.activeProfileId == job.profile && !sshState.isConnected) {
      unawaited(ssh.disconnect());
    }
    job.notify();
  }

  Future<bool> _challenge(
    _SshLogin job,
    ResearchHostKeyInfo info,
    String? previous,
  ) async {
    if (!identical(_login, job) || job.cancelled) return false;
    job.challenge = {
      'id': const Uuid().v4(),
      'fingerprint': info.fingerprintSha256,
      'key_type': info.keyType,
      'previous': previous,
    };
    final decision = Completer<bool>();
    job.decision = decision;
    job.notify();
    final result = await decision.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () => false,
    );
    job.challenge = null;
    job.decision = null;
    job.notify();
    return result;
  }

  Future<Map<String, Object?>> _loginStatus(
    _SshLogin job, {
    bool wait = true,
  }) async {
    if (wait && !job.done && job.challenge == null) {
      job.changed = Completer<void>();
      await job.changed.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () {},
      );
    }
    return page('ssh_progress', {
      'job_id': job.id,
      'profile': job.profile,
      'done': job.done,
      'connected':
          sshState.isConnected && sshState.activeProfileId == job.profile,
      'status': sshState.statusMessage,
      'challenge': job.challenge,
    });
  }

  Future<Map<String, Object?>> libraryList() async {
    final library = container.read(libraryRepositoryProvider),
        projects = container.read(projectRepositoryProvider);
    final counts = await projects.fileCounts();
    return page('library_list', {
      'sets': [
        for (final v in await projects.list())
          {'id': v.id, 'name': v.name, 'count': counts[v.id] ?? 0},
      ],
      'assets': [
        for (final v in await library.list())
          {
            'id': v.id,
            'name': v.name,
            'kind': v.kind.name,
            'size': v.sizeBytes,
            'mime': v.mimeType,
            'version': v.sha256,
          },
      ],
    });
  }

  Future<Map<String, Object?>> librarySet(String id) async {
    final repo = container.read(projectRepositoryProvider),
        library = container.read(libraryRepositoryProvider);
    final value = await repo.get(id);
    if (value == null) throw const BridgeFailure('not_found', '资料集已不存在');
    final ids = await repo.fileIds(id);
    return page('library_set', {
      'id': id,
      'name': value.name,
      'instructions': value.instructions,
      'version': version([value.name, value.instructions, ids]),
      'file_ids': ids,
      'assets': [
        for (final v in await library.list(kind: LibraryItemKind.file))
          {'id': v.id, 'name': v.name, 'selected': ids.contains(v.id)},
      ],
    });
  }

  Future<Map<String, Object?>> completeRemote(
    String profileId,
    String root,
    String query,
  ) async {
    if (!sshState.isConnected || sshState.activeProfileId != profileId) {
      throw const BridgeFailure('not_connected', '先用 /ssh 连接此服务器');
    }
    final normalized = query.replaceAll(r'\', '/');
    if (normalized.startsWith('/') ||
        normalized.contains(':') ||
        normalized.split('/').contains('..')) {
      throw const BridgeFailure('invalid_params', '只允许工作区内的相对路径');
    }
    final slash = normalized.lastIndexOf('/');
    final directory = slash < 0 ? '.' : normalized.substring(0, slash);
    final prefix = slash < 0 ? '' : normalized.substring(0, slash + 1);
    final filter = normalized.substring(slash + 1).toLowerCase();
    final session = await ssh.openWorkSession(profileId, root);
    try {
      final value = jsonDecode(
        await session.call('coding_list_directory', {
          'scope': 'root',
          'path': directory.isEmpty ? '.' : directory,
        }, CancelToken()),
      );
      final entries = value is List
          ? value
          : value is Map
          ? value['entries'] ?? value['files']
          : null;
      return {
        'files': [
          if (entries is List)
            for (final v in entries)
              if (v is Map &&
                  '${v['name'] ?? v['path']}'.toLowerCase().contains(filter))
                {
                  'path': '$prefix${v['name'] ?? v['path']}',
                  'kind':
                      v['kind'] ??
                      v['type'] ??
                      (v['directory'] == true ? 'directory' : 'file'),
                },
        ],
      };
    } finally {
      await session.close();
    }
  }

  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, dynamic> a,
  ) async {
    final action = requiredString(
      a,
      method == 'terminal.query' ? 'topic' : 'action',
    );
    final scope = requiredString(a, '_bridge_client_scope');
    final mutation = method == 'terminal.action';
    if (!mutation &&
        !const {
          'ssh.list',
          'ssh.profile',
          'ssh.status',
          'ssh.files',
          'ssh.read',
          'library.manage',
          'library.manage.set',
        }.contains(action)) {
      throw const BridgeFailure('invalid_params', '此操作需要明确执行');
    }
    switch (action) {
      case 'ssh.list':
        return sshList();
      case 'ssh.profile':
        return sshProfile(profile(requiredString(a, 'id')));
      case 'ssh.save':
        final id = a['id'] as String?;
        final old = id == null || id.isEmpty ? null : profile(id);
        if (old != null && a['version'] != version(old.toJson())) {
          throw const BridgeFailure('conflict', 'SSH 配置已变化，请重新打开');
        }
        if (old?.id == sshState.activeProfileId) idle();
        final port = int.tryParse('${a['port']}');
        if (port == null || port < 1 || port > 65535) {
          throw const BridgeFailure('invalid_params', '端口应为 1–65535');
        }
        final host = requiredString(a, 'host').trim(),
            username = requiredString(a, 'username').trim();
        if (RegExp(r'[\s\x00-\x1f]').hasMatch(host) ||
            username.contains('\n')) {
          throw const BridgeFailure('invalid_params', 'SSH 地址或用户名无效');
        }
        final sameHost = old?.host == host && old?.port == port;
        late final List<SshRemoteForward> forwards;
        try {
          forwards = a.containsKey('remote_forward')
              ? SshRemoteForward.parseLines(
                  a['remote_forward'] as String? ?? '',
                )
              : old?.remoteForwards ?? const [];
        } on FormatException catch (error) {
          throw BridgeFailure('invalid_params', error.message);
        }
        final value = SshProfile(
          id: old?.id ?? const Uuid().v4(),
          name: requiredString(a, 'name').trim(),
          host: host,
          port: port,
          username: username,
          remoteForwards: forwards,
          authType: a['authType'] == 'privateKey'
              ? SshAuthType.privateKey
              : SshAuthType.password,
          trustedHostKeyFingerprint: sameHost
              ? old?.trustedHostKeyFingerprint
              : null,
          lastUsedAt: old?.lastUsedAt,
        );
        String? key;
        final keyPath = a['private_key_file'] as String?;
        if (keyPath != null && keyPath.trim().isNotEmpty) {
          final file = File(keyPath.trim());
          if (await file.length() > 256 * 1024) {
            throw const BridgeFailure('too_large', '私钥文件过大');
          }
          key = await file.readAsString();
        }
        final passwordValue = a['password'] as String?,
            passphraseValue = a['passphrase'] as String?;
        final password = passwordValue?.isEmpty == true ? null : passwordValue;
        final passphrase = passphraseValue?.isEmpty == true
            ? null
            : passphraseValue;
        rememberSecrets([?key, ?password, ?passphrase]);
        await ssh.saveProfile(
          value,
          password: password,
          privateKeyPem: key,
          passphrase: passphrase,
        );
        return sshProfile(value);
      case 'ssh.connect':
        idle();
        final value = profile(requiredString(a, 'id'));
        if (sshState.isConnected && sshState.activeProfileId == value.id) {
          return sshProfile(value);
        }
        if (_login != null && !_login!.done) {
          throw const BridgeFailure('busy', '另一 SSH 连接正在进行');
        }
        final job = _SshLogin(const Uuid().v4(), scope, value.id);
        _login = job;
        unawaited(
          ssh
              .connectWithHostKey(
                value,
                onTrust: (i) => _challenge(job, i, null),
                onMismatch: (i, previous) => _challenge(job, i, previous),
              )
              .catchError((Object _) {
                job.cancelled = true;
              })
              .whenComplete(() {
                job.done = true;
                job.notify();
              }),
        );
        return _loginStatus(job);
      case 'ssh.status':
      case 'ssh.trust':
      case 'ssh.cancel':
        final job = _login;
        if (job == null || job.id != a['job_id'] || job.scope != scope) {
          throw const BridgeFailure('not_found', 'SSH 连接任务已结束');
        }
        if (action == 'ssh.trust') {
          if (job.challenge?['id'] != a['challenge_id'] ||
              job.decision == null) {
            throw const BridgeFailure('conflict', '指纹确认已过期');
          }
          if (job.decision!.isCompleted) {
            throw const BridgeFailure('conflict', '指纹已处理，请等待连接结果');
          }
          job.decision!.complete(a['accept'] == true);
          job.challenge = null;
        } else if (action == 'ssh.cancel' && !job.done) {
          job.cancelled = true;
          if (job.decision?.isCompleted == false) job.decision!.complete(false);
          await ssh.disconnect();
          job.done = true;
          job.notify();
        }
        return _loginStatus(job);
      case 'ssh.disconnect':
        idle();
        confirmed(a);
        connection(a);
        await ssh.disconnect();
        return sshList();
      case 'ssh.delete':
        idle();
        confirmed(a);
        await ssh.deleteProfile(profile(requiredString(a, 'id')).id);
        return sshList();
      case 'ssh.files':
        connection(a);
        final path = await ssh.files.absolute(a['path'] as String? ?? '.');
        final values = await ssh.files.list(path);
        return page('ssh_files', {
          'profile': a['profile'],
          'generation': a['generation'],
          'path': path,
          'parent': p.posix.dirname(path),
          'files': [
            for (final v in values)
              {
                'name': v.name,
                'path': v.path,
                'directory': v.directory,
                'size': v.size,
              },
          ],
        });
      case 'ssh.read':
        connection(a);
        final path = requiredString(a, 'path');
        final text = await ssh.files.readText(path);
        return page('ssh_text', {
          'profile': a['profile'],
          'generation': a['generation'],
          'path': path,
          'text': text,
          'version': version(text),
        });
      case 'ssh.write':
        idle();
        confirmed(a);
        connection(a);
        final path = requiredString(a, 'path');
        final original = await ssh.files.readText(path);
        if (a['version'] != version(original)) {
          throw const BridgeFailure('conflict', '远端文件已变化，请重新读取');
        }
        await ssh.files.saveText(
          path,
          a['text'] as String? ?? '',
          original: original,
        );
        return page('ssh_text', {
          'profile': a['profile'],
          'generation': a['generation'],
          'path': path,
          'text': a['text'],
          'version': version(a['text'] ?? ''),
          'notice': '已保存远端文件',
        });
      case 'ssh.use':
        idle();
        connection(a);
        final sessionId = requiredString(a, 'session_id');
        final root = await ssh.files.absolute(requiredString(a, 'path'));
        final policy =
            container.read(sessionPolicyProvider)[sessionId] ??
            const SessionPolicy();
        await container
            .read(sessionPolicyProvider.notifier)
            .save(
              sessionId,
              policy.copyWith(
                sshProfileId: a['profile'] as String,
                remoteRoot: root,
              ),
            );
        return {...sshList(), 'notice': '当前会话已使用 SSH 工作区 $root'};
      case 'library.manage':
        return libraryList();
      case 'library.manage.set':
        return librarySet(requiredString(a, 'id'));
      case 'library.manage.save':
        final id = a['id'] as String?;
        if (id != null && id.isNotEmpty) {
          final old = await librarySet(id);
          if (old['version'] != a['version']) {
            throw const BridgeFailure('conflict', '资料集已变化，请重新打开');
          }
        }
        final key = await container
            .read(projectRepositoryProvider)
            .save(
              id: id == null || id.isEmpty ? null : id,
              name: requiredString(a, 'name'),
              instructions: a['instructions'] as String? ?? '',
              fileIds: (a['file_ids'] as List? ?? [])
                  .whereType<String>()
                  .toList(),
            );
        return librarySet(key);
      case 'library.manage.delete':
        idle();
        confirmed(a);
        await chat.deleteProject(requiredString(a, 'id'));
        return libraryList();
      case 'library.manage.use':
        idle();
        await chat.assignProject(
          requiredString(a, 'session_id'),
          a['id'] as String?,
        );
        return {
          ...await libraryList(),
          'notice': a['id'] == null ? '已取消资料集绑定' : '当前会话已使用此资料集',
        };
      case 'library.manage.import':
        final file = File(requiredString(a, 'path'));
        if (await file.length() > 15 * 1024 * 1024) {
          throw const BridgeFailure('too_large', '资料导入上限 15 MiB');
        }
        final bytes = await file.readAsBytes();
        await container
            .read(libraryRepositoryProvider)
            .importBytes(
              name: p.basename(file.path),
              mimeType: AttachmentIngestor.mimeFor(
                p.extension(file.path).replaceFirst('.', ''),
              ),
              bytes: bytes,
            );
        return libraryList();
      case 'library.manage.remove':
        idle();
        confirmed(a);
        await container
            .read(libraryRepositoryProvider)
            .delete(requiredString(a, 'id'));
        return libraryList();
    }
    throw const BridgeFailure('unsupported', '未知管理操作');
  }
}
