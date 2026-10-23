import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/desktop_providers.dart';
import '../../../domain/desktop/workspace_tools.dart';
import '../../../state/research_terminal_controller.dart';
import '../../../state/work_changes.dart';

Future<WorkToolSession> openDeliverySession(
  WidgetRef ref,
  WorkFileChange file,
  CancelToken token,
) async {
  final target = jsonDecode(file.target) as Map;
  final WorkToolSession session;
  if (target['kind'] == 'local') {
    session = await WorkspaceToolSession.open(
      ref.read(desktopWorkspaceHostProvider),
      target['workspaceId'] as String,
      token,
    );
  } else if (target['kind'] == 'ssh') {
    session = await ref
        .read(researchTerminalProvider.notifier)
        .openWorkSession(
          target['profileId'] as String,
          target['root'] as String,
        );
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
  return session;
}
