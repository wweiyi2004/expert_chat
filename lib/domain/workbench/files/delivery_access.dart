import 'package:path/path.dart' as p;
import '../../../domain/desktop/agent_workspace_isolation.dart';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import '../../../core/desktop_providers.dart';
import '../../../domain/desktop/workspace_tools.dart';
import '../../../state/research_terminal_controller.dart';
import '../../../state/work_changes.dart';

typedef WorkspaceProviderReader = T Function<T>(ProviderListenable<T> provider);

Future<WorkToolSession> openDeliverySessionUsing(
  WorkspaceProviderReader read,
  WorkFileChange file,
  CancelToken token,
) async {
  final target = jsonDecode(file.target) as Map;
  final WorkToolSession session;
  if (target['kind'] == 'local') {
    session = await WorkspaceToolSession.open(
      read(desktopWorkspaceHostProvider),
      target['workspaceId'] as String,
      token,
    );
  } else if (target['kind'] == 'ssh') {
    session = await read(
      researchTerminalProvider.notifier,
    ).openWorkSession(target['profileId'] as String, target['root'] as String);
  } else {
    throw StateError('无法定位文件的原工作区');
  }
  if ((jsonDecode(session.changeTarget) as Map)['root'] != target['root']) {
    await session.close();
    throw StateError('文件原工作区已变化，请重新选择对应目录');
  }
  if (session is WorkspaceToolSession && target['scopes'] is Map) {
    final original = (target['scopes'] as Map)[file.scope];
    final current = session.workspace.scopes
        .where((scope) => scope.name == file.scope)
        .firstOrNull
        ?.path;
    if (original != current) {
      await session.close();
      throw StateError('文件原目录的映射已变化，未打开其他目录中的同名文件');
    }
  }
  final effective =
      target['pathPrefix'] is String && session is WorkspaceToolSession
      ? IsolatedWorktreeToolSession.fromParent(
          session,
          target['pathPrefix'] as String,
        )
      : session;
  if (file.isDelivery &&
      effective.tools.any((tool) => tool.name == 'coding_artifact_manifest')) {
    try {
      final actual =
          jsonDecode(
                await effective.call('coding_artifact_manifest', {
                  'scope': file.scope,
                  'path': file.path,
                }, token),
              )
              as Map;
      if (actual['sha256'] != file.deliveryHash) {
        throw StateError('已登记成果的实际版本已改变；此交付已过期，请重新核验登记。');
      }
    } catch (_) {
      await effective.close();
      rethrow;
    }
  }
  return effective;
}

/// Resolve only after a fresh authorized metadata/hash check, never a binary
/// preview. Works for files, directories and parent-bound isolated sessions.
Future<String> authorizedDeliveryLocalPath(
  WorkToolSession session,
  WorkFileChange file,
  CancelToken token,
) async {
  final target = jsonDecode(session.changeTarget) as Map;
  if (target['kind'] != 'local') throw StateError('远端成果请在工作台查看');
  final metadata =
      jsonDecode(
            await session.call('coding_artifact_manifest', {
              'scope': file.scope,
              'path': file.path,
            }, token),
          )
          as Map;
  if (file.isDelivery && metadata['sha256'] != file.deliveryHash) {
    throw StateError('成果版本已改变，请重新核验登记');
  }
  final scopes = target['scopes'] as Map?;
  final mapped = scopes?[file.scope];
  if (mapped is! String) throw StateError('成果原目录授权不可用');
  final root = p.normalize(
    p.isAbsolute(mapped) ? mapped : p.join(target['root'] as String, mapped),
  );
  final prefix = target['pathPrefix'] as String? ?? '';
  final resolved = p.normalize(p.join(root, prefix, file.path));
  if (!p.equals(root, resolved) && !p.isWithin(root, resolved)) {
    throw StateError('成果路径超出授权目录');
  }
  if (p.equals(root, resolved) && metadata['kind'] != 'directory') {
    throw StateError('根目录成果类型不匹配');
  }
  return resolved.startsWith(r'\\?\UNC\')
      ? r'\\' + resolved.substring(8)
      : resolved.startsWith(r'\\?\')
      ? resolved.substring(4)
      : resolved;
}
