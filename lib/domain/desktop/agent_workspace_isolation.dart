import 'dart:convert';
import '../../platform/foundation.dart';
import 'package:dio/dio.dart';
import 'workspace_host.dart';
import 'workspace_tools.dart';

/// Worktrees stay beneath the original granted root. A clone never supplies a
/// new authority: every operation rechecks the original complete RW grant.
class AgentWorkspaceIsolation {
  AgentWorkspaceIsolation._(
    this.parent,
    this.workspace,
    this.host,
    this.prefix,
    this.baseline, {
    this.baselineIdentities = const {},
  });
  final WorkspaceToolSession parent;
  final DesktopWorkspace workspace;
  final DesktopWorkspaceHost host;
  final String prefix;
  final Map<String, String> baseline;
  final Map<String, String> baselineIdentities;
  Map<String, dynamic> get recoveryMetadata => {
    'version': 1,
    'workspace_id': parent.workspace.id,
    'parent_root': parent.workspace.root,
    'prefix': prefix,
    'baseline': baseline,
    'baseline_identities': baselineIdentities,
  };

  static Future<AgentWorkspaceIsolation> restore({
    required WorkspaceToolSession parent,
    required DesktopWorkspaceHost host,
    required Map<String, dynamic> metadata,
    required CancelToken token,
  }) async {
    if (metadata['version'] != 1 ||
        metadata['workspace_id'] != parent.workspace.id ||
        metadata['parent_root'] != parent.workspace.root) {
      throw StateError('隔离恢复宿主与原父工作区不一致');
    }
    await parent.authorizeCommand();
    final prefix = metadata['prefix'] as String;
    if (!RegExp(r'^\.expert-agent-worktrees/[a-zA-Z0-9-]+$').hasMatch(prefix)) {
      throw StateError('隔离恢复路径无效');
    }
    final baseline = Map<String, String>.from(metadata['baseline'] as Map);
    final identities = Map<String, String>.from(
      metadata['baseline_identities'] as Map? ?? {},
    );
    if (baseline.entries.any(
      (e) => e.value != 'new' && !identities.containsKey(e.key),
    )) {
      throw StateError('历史隔离基线缺少文件身份，不能安全恢复');
    }
    if (baseline.length > 1000 ||
        baseline.entries.any(
          (e) =>
              e.key.isEmpty ||
              e.key.startsWith('/') ||
              e.key.contains(':') ||
              e.key
                  .replaceAll(r'\', '/')
                  .split('/')
                  .any((v) => v == '..' || v == '.') ||
              (e.value != 'new' &&
                  !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(e.value)),
        )) {
      throw StateError('隔离恢复基线无效');
    }
    final id = prefix.split('/').last;
    final saved =
        jsonDecode(
              await parent.call('coding_read_file', {
                'scope': 'root',
                'path': '.expert-agent-worktrees/.baseline-$id.json',
              }, token),
            )
            as Map;
    final document = jsonDecode(saved['content'] as String) as Map;
    final diskBaseline = Map<String, String>.from(document['files'] as Map);
    final diskIdentities = Map<String, String>.from(
      document['identities'] as Map? ?? {},
    );
    if (document['prefix'] != prefix ||
        diskBaseline.length != baseline.length ||
        baseline.entries.any((e) => diskBaseline[e.key] != e.value) ||
        identities.length != diskIdentities.length ||
        identities.entries.any((e) => diskIdentities[e.key] != e.value)) {
      throw StateError('隔离基线文件已变化，恢复被拒绝');
    }
    // Host resolution rejects escaped/symlinked worktrees and permissions are
    // checked again on every operation through the original parent authority.
    await parent.call('coding_list_directory', {
      'scope': 'root',
      'path': prefix,
    }, token);
    await parent.call('coding_read_file', {
      'scope': 'root',
      'path': '$prefix/.git',
    }, token);
    return AgentWorkspaceIsolation._(
      parent,
      DesktopWorkspace(
        id: parent.workspace.id,
        name: 'Agent $id',
        root: '${parent.workspace.root}/$prefix',
        scopes: const [],
      ),
      host,
      prefix,
      Map.unmodifiable(baseline),
      baselineIdentities: Map.unmodifiable(identities),
    );
  }

  static Future<AgentWorkspaceIsolation> create({
    required WorkspaceToolSession parent,
    required DesktopWorkspaceHost host,
    required String id,
    required CancelToken token,
    required Future<bool> Function(String command) approve,
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id)) {
      throw ArgumentError('Invalid isolation identity');
    }
    await parent.authorizeCommand();
    final prefix = '.expert-agent-worktrees/$id';
    final command = 'git worktree add --detach -- "$prefix" HEAD';
    if (!await approve(command)) throw StateError('独立工作树创建未获批准');
    if (token.isCancelled) throw token.cancelError!;
    Future<String> checked(String command) async {
      final output = StringBuffer();
      var confirmed = false;
      final result = await parent.call(
        'work_run_command',
        {'command': command, 'timeout_seconds': 120},
        token,
        onOutput: (text, isStderr) {
          if (!isStderr) {
            if (output.length + text.length > 1024 * 1024) {
              throw StateError('基线路径列表超过 1MiB');
            }
            output.write(text);
          }
        },
        onComplete: (outcome) {
          confirmed =
              !outcome.cancelled && !outcome.timedOut && outcome.exitCode == 0;
        },
      );
      if (!confirmed) throw StateError('基线命令未完成：$result');
      return output.toString();
    }

    const excluded = "-- . ':(exclude).expert-agent-worktrees/**'";
    final listed = await checked(
      'git ls-files --cached --others --exclude-standard -z $excluded',
    );
    final changed = await checked('git diff --name-only -z HEAD $excluded');
    final untracked = (await checked(
      'git ls-files --others --exclude-standard -z $excluded',
    )).split('\u0000').where((s) => s.isNotEmpty).toSet();
    final paths = {...listed.split('\u0000'), ...changed.split('\u0000')}
      ..remove('');
    if (paths.length > 1000) {
      throw StateError('隔离基线超过 1000 文件；请缩小项目或使用共享文件职责，原项目未改变');
    }
    final baseline = <String, String>{};
    final identities = <String, String>{};
    final listings = <String, Map>{};
    Future<bool> exists(String path, {bool refresh = false}) async {
      final normalized = path.replaceAll(r'\', '/');
      final slash = normalized.lastIndexOf('/');
      final directory = slash < 0 ? '.' : normalized.substring(0, slash);
      final name = normalized.substring(slash + 1);
      if (refresh) listings.remove(directory);
      final listing = listings[directory] ??=
          jsonDecode(
                await parent.call('coding_list_directory', {
                  'scope': 'root',
                  'path': directory,
                }, token),
              )
              as Map;
      if (listing['truncated'] == true) throw StateError('基线目录清单被截断，未启动子代理');
      final entries = listing['entries'] as List;
      return entries.any((e) => e['name'] == name);
    }

    for (final path in paths) {
      if (await exists(path)) {
        final info =
            jsonDecode(
                  await parent.call('coding_artifact_manifest', {
                    'scope': 'root',
                    'path': path,
                  }, token),
                )
                as Map;
        if (info['kind'] != 'file') throw StateError('基线包含非普通文件：$path');
        baseline[path] = info['sha256'] as String;
        identities[path] = info['identity'] as String;
      } else {
        baseline[path] = 'new';
      }
    }
    try {
      await parent.call('coding_list_directory', {
        'scope': 'root',
        'path': '.expert-agent-worktrees',
      }, token);
    } catch (_) {
      await parent.call('coding_create_directory', {
        'scope': 'root',
        'path': '.expert-agent-worktrees',
      }, token);
    }
    final patch = '.expert-agent-worktrees/.baseline-$id.patch';
    await checked('git diff --binary HEAD --output="$patch" $excluded');
    var confirmed = false;
    final result = await parent.call(
      'work_run_command',
      {'command': command, 'timeout_seconds': 120},
      token,
      onComplete: (outcome) {
        confirmed =
            !outcome.cancelled && !outcome.timedOut && outcome.exitCode == 0;
      },
    );
    if (!confirmed) throw StateError('独立工作树创建未确认成功，未启动子代理；请检查 $prefix。$result');
    var hostRoot = parent.workspace.root;
    if (hostRoot.startsWith(r'\\?\UNC\')) {
      hostRoot = r'\\' + hostRoot.substring(8);
    } else if (hostRoot.startsWith(r'\\?\')) {
      hostRoot = hostRoot.substring(4);
    }
    final patchAbsolute = '$hostRoot/$patch'.replaceAll("'", "''");
    await checked(
      "git -C '$prefix' apply --binary --allow-empty '$patchAbsolute'",
    );
    final createdDirs = <String>{};
    for (final path in untracked) {
      final hash = baseline[path];
      if (hash == null || hash == 'new') continue;
      final parts = path.replaceAll(r'\', '/').split('/');
      var directory = prefix;
      for (final part in parts.take(parts.length - 1)) {
        directory = '$directory/$part';
        if (createdDirs.add(directory)) {
          try {
            await parent.call('coding_list_directory', {
              'scope': 'root',
              'path': directory,
            }, token);
          } catch (_) {
            await parent.call('coding_create_directory', {
              'scope': 'root',
              'path': directory,
            }, token);
          }
        }
      }
      await parent.call('coding_copy_file', {
        'scope': 'root',
        'source': path,
        'destination': '$prefix/$path',
        'expected_sha256': hash,
      }, token);
    }
    listings.clear();
    for (final entry in baseline.entries) {
      if (entry.value == 'new') {
        if (await exists(entry.key)) {
          throw StateError('父项目在准备期间变化，未启动子代理：${entry.key}');
        }
        continue;
      }
      final parentInfo =
          jsonDecode(
                await parent.call('coding_artifact_manifest', {
                  'scope': 'root',
                  'path': entry.key,
                }, token),
              )
              as Map;
      final childInfo =
          jsonDecode(
                await parent.call('coding_artifact_manifest', {
                  'scope': 'root',
                  'path': '$prefix/${entry.key}',
                }, token),
              )
              as Map;
      if (parentInfo['sha256'] != entry.value ||
          parentInfo['identity'] != identities[entry.key]) {
        throw StateError('父项目在准备期间变化，未启动子代理：${entry.key}');
      }
      if (childInfo['sha256'] != entry.value) {
        // Git checkout filters/CRLF can alter otherwise clean tracked bytes.
        // Hydrate the exact observed authorized source, guarded on both ends.
        await parent.call('coding_copy_file', {
          'scope': 'root',
          'source': entry.key,
          'destination': '$prefix/${entry.key}',
          'expected_sha256': entry.value,
          'destination_expected_sha256': childInfo['sha256'],
        }, token);
        final verified =
            jsonDecode(
                  await parent.call('coding_artifact_manifest', {
                    'scope': 'root',
                    'path': '$prefix/${entry.key}',
                  }, token),
                )
                as Map;
        if (verified['sha256'] != entry.value) {
          throw StateError('隔离副本未能精确复现基线：${entry.key}');
        }
      }
    }
    await parent.call('coding_write_file', {
      'scope': 'root',
      'path': '.expert-agent-worktrees/.baseline-$id.json',
      'content': jsonEncode({
        'version': 1,
        'prefix': prefix,
        'files': baseline,
        'identities': identities,
        'ignored_untracked': 'excluded by git --exclude-standard',
      }),
      'expected_sha256': 'new',
    }, token);
    await parent.authorizeCommand();
    final workspace = DesktopWorkspace(
      id: parent.workspace.id,
      name: 'Agent $id',
      root: '${parent.workspace.root}/$prefix',
      scopes: const [],
    );
    return AgentWorkspaceIsolation._(
      parent,
      workspace,
      host,
      prefix,
      Map.unmodifiable(baseline),
      baselineIdentities: Map.unmodifiable(identities),
    );
  }

  Future<
    ({
      Map<String, dynamic> receipt,
      String? before,
      String? after,
      bool binary,
      bool deleted,
    })
  >
  integrateFile(
    String path,
    String expectedSourceHash,
    CancelToken token,
  ) async {
    final normalized = path.replaceAll(r'\', '/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        normalized.contains(':') ||
        normalized.split('/').any((v) => v == '..' || v == '.')) {
      throw StateError('成果必须是规范的工作区相对文件路径');
    }
    // Windows file identities are case insensitive. Use the baseline's exact
    // spelling, including dirty/untracked files, rather than treating aliases
    // as new destinations.
    final matches = baseline.keys
        .where(
          (v) => defaultTargetPlatform == TargetPlatform.windows
              ? v.toLowerCase() == normalized.toLowerCase()
              : v == normalized,
        )
        .toList();
    if (matches.length > 1) throw StateError('隔离基线路径大小写冲突');
    final destination = matches.isEmpty ? normalized : matches.single;
    final expected = baseline[destination] ?? 'new';
    await parent.authorizeCommand();
    final original = await WorkspaceToolSession.open(
      host,
      parent.workspace.id,
      token,
    );
    try {
      Future<String?> text(String targetPath, String hash) async {
        if (hash == 'new') return null;
        try {
          final data =
              jsonDecode(
                    await original.call('coding_read_file', {
                      'scope': 'root',
                      'path': targetPath,
                    }, token),
                  )
                  as Map;
          return data['sha256'] == hash ? data['content'] as String : null;
        } catch (_) {
          // Binary and large files are copied by the host without decoding.
          return null;
        }
      }

      final before = await text(destination, expected);
      final deleted = expectedSourceHash == 'deleted';
      if (deleted) {
        if (expected == 'new') throw StateError('基线不存在此文件，不能整合删除');
        final receipt = Map<String, dynamic>.from(
          jsonDecode(
                await original.call('coding_delete_file_if_current', {
                  'scope': 'root',
                  'path': destination,
                  'expected_sha256': expected,
                  'source_absent_path': '$prefix/$normalized',
                  'expected_identity': baselineIdentities[destination],
                }, token),
              )
              as Map,
        );
        return (
          receipt: receipt,
          before: before,
          after: null,
          binary: before == null,
          deleted: true,
        );
      }
      final after = await text('$prefix/$normalized', expectedSourceHash);
      final receipt = Map<String, dynamic>.from(
        jsonDecode(
              await original.call('coding_copy_file', {
                'scope': 'root',
                'source': '$prefix/$normalized',
                'destination': destination,
                'expected_sha256': expectedSourceHash,
                if (expected != 'new') 'destination_expected_sha256': expected,
                if (expected != 'new')
                  'destination_expected_identity':
                      baselineIdentities[destination],
              }, token),
            )
            as Map,
      );
      return (
        receipt: receipt,
        before: before,
        after: after,
        binary: after == null || (expected != 'new' && before == null),
        deleted: false,
      );
    } finally {
      await original.close();
    }
  }

  Future<WorkToolSession> open(CancelToken token) async {
    await parent.authorizeCommand();
    return IsolatedWorktreeToolSession(
      this,
      await WorkspaceToolSession.open(host, parent.workspace.id, token),
    );
  }
}

class IsolatedWorktreeToolSession implements WorkToolSession {
  IsolatedWorktreeToolSession(
    AgentWorkspaceIsolation isolation,
    WorkspaceToolSession inner,
  ) : this.fromParent(inner, isolation.prefix);
  IsolatedWorktreeToolSession.fromParent(this.inner, this.prefix) {
    if (!RegExp(r'^\.expert-agent-worktrees/[a-zA-Z0-9-]+$').hasMatch(prefix)) {
      throw ArgumentError('Invalid worktree prefix');
    }
  }
  final String prefix;
  final WorkspaceToolSession inner;
  @override
  get tools => inner.tools;
  @override
  String get guidance =>
      '${inner.guidance}\n独立工作树，父工作区仍是权限来源。向主代理报告成果时加前缀 $prefix/；不得自动合并或推送。';
  @override
  String get target => '独立工作树 · ${inner.workspace.root}/$prefix';
  @override
  String get changeTarget => jsonEncode({
    ...jsonDecode(inner.changeTarget) as Map,
    'pathPrefix': prefix,
  });
  @override
  Future<String> call(
    String name,
    Map<String, dynamic> arguments,
    CancelToken token, {
    onOutput,
    onComplete,
  }) async {
    await inner.authorizeCommand();
    final args = Map<String, dynamic>.from(arguments);
    if (name == 'work_run_command') {
      final command = args['command'] as String;
      args['command'] = defaultTargetPlatform == TargetPlatform.windows
          ? "Set-Location -LiteralPath '$prefix'; if (-not \$?) { exit 1 }; $command"
          : "cd -- '$prefix' && $command";
    } else {
      if (args['scope'] != null && args['scope'] != 'root') {
        throw StateError('隔离工作树仅开放继承根目录内的 root scope');
      }
      args['scope'] = 'root';
      if (name == 'coding_copy_file') {
        for (final key in ['source', 'destination']) {
          final path = args[key] as String;
          if (path.startsWith('/') ||
              path.contains(':') ||
              path.replaceAll(r'\', '/').split('/').contains('..')) {
            throw StateError('路径越出隔离工作树');
          }
          args[key] = '$prefix/$path';
        }
      }
      final path = args['path'] as String?;
      if (path != null) {
        final normalized = path.replaceAll(r'\', '/');
        if (normalized.startsWith('/') ||
            normalized.contains(':') ||
            normalized.split('/').contains('..')) {
          throw StateError('路径越出隔离工作树');
        }
        args['path'] = '$prefix/$normalized';
      }
    }
    final result = await inner.call(
      name,
      args,
      token,
      onOutput: onOutput,
      onComplete: onComplete,
    );
    if (name == 'work_run_command') return result;
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map) {
        final output = Map<String, dynamic>.from(decoded);
        if (name == 'coding_workspace_info') {
          output['workspace'] = {
            'id': inner.workspace.id,
            'name': '隔离工作树',
            'root': '${inner.workspace.root}/$prefix',
            'scopes': {
              'root': {
                'name': 'root',
                'path': '${inner.workspace.root}/$prefix',
                'access': 'read-write',
              },
            },
          };
        }
        if (arguments['destination'] != null) {
          output['path'] = arguments['destination'];
        }
        if (arguments['path'] != null) output['path'] = arguments['path'];
        if (output['entries'] is List) {
          output['entries'] = [
            for (final item in output['entries'] as List)
              if (item is Map && item['path'] is String)
                {
                  ...item,
                  'path': (item['path'] as String).replaceFirst('$prefix/', ''),
                }
              else
                item,
          ];
        }
        return jsonEncode(output);
      }
    } catch (_) {}
    return result;
  }

  @override
  Future<void> close() => inner.close();
}
