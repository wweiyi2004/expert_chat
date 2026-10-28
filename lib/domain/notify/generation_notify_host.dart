/// The host keeps running independently; clients render these public events.
class GenerationNotify {
  static final _sessions = <String>{};
  static void Function(Map<String, Object?> event)? onEvent;
  static bool get inBackground => true;
  static bool get hasActiveSessions => _sessions.isNotEmpty;
  static Future<void> init() async {}
  static void setAppBackground(bool value) {}
  static Future<void> onGenerationStart({String? sessionId}) async {
    _sessions.add(sessionId ?? 'legacy');
    onEvent?.call({'type': 'generation.started', 'session_id': sessionId});
  }

  static Future<void> onGenerationEnd({
    String? sessionId,
    required bool success,
    required String conversationTitle,
    String? preview,
    bool cancelled = false,
  }) async {
    _sessions.remove(sessionId ?? 'legacy');
    onEvent?.call({
      'type': 'generation.ended',
      'session_id': sessionId,
      'success': success,
      'cancelled': cancelled,
    });
  }
}
