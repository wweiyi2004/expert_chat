part of 'backend.dart';

extension ExternalSessionCommands on ControllerBridgeBackend {
  Future<Map<String, Object?>?> _externalSessionCommand(
    String method,
    Map<String, dynamic> a,
  ) async {
    final topic = a[method == 'terminal.query' ? 'topic' : 'action'];
    if (method == 'terminal.query' && topic == 'session.imports') {
      late final List<ExternalSessionCandidate> rows;
      try {
        rows = await _externalSessions.discover();
      } catch (_) {
        throw const BridgeFailure(
          'session_discovery_failed',
          '暂时无法读取外部会话记录，不影响当前工作区；可稍后使用 /import 重试。',
        );
      }
      return {
        'sessions': rows.map((r) => r.summary()).toList(),
        'notice': '仅导入对话文字；不转移密钥、工具权限或运行中的任务。最近保存不代表来源程序已退出。',
      };
    }
    if (method == 'terminal.query' && topic == 'session.import.preview') {
      final candidate = _externalSessions.candidate(requiredString(a, 'id'));
      final preview = candidate.messages
          .take(12)
          .map((m) => '${m['role']}: ${m['text']}')
          .join('\n\n');
      return {
        ...candidate.summary(),
        'preview': preview.substring(0, preview.length.clamp(0, 8000)),
      };
    }
    if (method == 'terminal.action' && topic == 'session.import') {
      if (a['confirmed'] != true) {
        throw const BridgeFailure('confirmation_required', '请先预览并确认导入');
      }
      final current = a['session_id'] as String?;
      if (current != null) _idle(current);
      final candidate = await _externalSessions.reviewed(
        requiredString(a, 'id'),
        requiredString(a, 'fingerprint'),
      );
      final imported = await controller.importExternalConversation(
        candidate.source,
        candidate.title,
        candidate.messages,
      );
      if (current != null) {
        await container
            .read(conversationWorkspaceBindingsProvider.notifier)
            .select(
              imported,
              container.read(conversationWorkspaceBindingsProvider)[current],
            );
      }
      return {'session_id': imported, 'notice': '已导入为新会话；来源记录保留，未重放工具或模型请求'};
    }
    return null;
  }
}
