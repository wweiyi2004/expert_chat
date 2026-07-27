import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps generation from sleeping the device and notifies when a turn finishes
/// while the app is backgrounded.
class GenerationNotify {
  GenerationNotify._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static var _ready = false;
  static var _inBackground = false;
  static var _generating = false;

  static bool get inBackground => _inBackground;

  static Future<void> init() async {
    if (_ready || kIsWeb) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_expert_chat');
      const darwin = DarwinInitializationSettings();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: android,
          iOS: darwin,
          macOS: darwin,
        ),
      );
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.requestNotificationsPermission();
      _ready = true;
    } catch (_) {
      // Notifications are best-effort; chat must keep working.
    }
  }

  static void setAppBackground(bool value) {
    _inBackground = value;
  }

  static Future<void> onGenerationStart() async {
    _generating = true;
    if (kIsWeb) return;
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  static Future<void> onGenerationEnd({
    required bool success,
    required String conversationTitle,
    String? preview,
    bool cancelled = false,
  }) async {
    final wasGenerating = _generating;
    _generating = false;
    if (kIsWeb) return;
    try {
      await WakelockPlus.disable();
    } catch (_) {}

    if (!wasGenerating || cancelled || !_inBackground) return;
    await init();
    if (!_ready) return;

    final title = success ? '回复已生成' : '生成未完成';
    final clippedTitle = _clip(conversationTitle, 40);
    final body = success
        ? (preview == null || preview.trim().isEmpty
              ? '「$clippedTitle」可以回来查看了'
              : '「$clippedTitle」：${_clip(preview, 80)}')
        : '「$clippedTitle」生成中断或失败，打开应用查看';

    try {
      await _plugin.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'generation',
            '生成完成',
            channelDescription: '后台生成完成或失败时提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }

  static String _clip(String s, int n) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.characters.length <= n) return t;
    return '${t.characters.take(n)}…';
  }
}
