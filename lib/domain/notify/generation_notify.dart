import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'generation_keep_alive.dart';

/// Protects active generation and notifies when a background turn finishes.
class GenerationNotify {
  GenerationNotify._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static final _keepAlive = GenerationKeepAlive();
  static var _ready = false;
  static var _inBackground = false;
  static final _sessions = <String>{};
  static bool get _generating => _sessions.isNotEmpty;
  static var _revision = 0;

  static bool get inBackground => _inBackground;

  /// Safe to call after the first frame (Activity must exist on Android).
  ///
  /// Never request runtime permissions from [main] before [runApp] — that
  /// crashes on several OEM Android builds.
  static Future<void> init() async {
    if (_ready || kIsWeb) return;
    try {
      // Status-bar icons must be monochrome drawables, not the full-color
      // launcher mipmap (can throw / hard-crash on some devices).
      const android = AndroidInitializationSettings('@drawable/ic_stat_notify');
      const darwin = DarwinInitializationSettings();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: android,
          iOS: darwin,
          macOS: darwin,
        ),
      );
      _ready = true;
    } catch (_) {
      // Notifications are best-effort; chat must keep working.
    }
  }

  /// Ask for POST_NOTIFICATIONS only when we are about to show something.
  static Future<void> _ensureAndroidPermission() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.requestNotificationsPermission();
    } catch (_) {}
  }

  static void setAppBackground(bool value) {
    _inBackground = value;
  }

  static Future<void> onGenerationStart({String? sessionId}) async {
    if (!_sessions.add(sessionId ?? 'legacy')) return;
    final revision = ++_revision;
    // Start before notification initialization/permission awaits, while the
    // user's send action still has a foreground Activity.
    await _keepAlive.start();
    if (!_generating || revision != _revision) return;
    if (kIsWeb) return;
    // Request notification permission while still foreground. Doing this only
    // in onGenerationEnd (often backgrounded) is ignored on Android 13+.
    await init();
    if (_generating && revision == _revision && !_inBackground) {
      await _ensureAndroidPermission();
    }
  }

  static Future<void> onGenerationEnd({
    String? sessionId,
    required bool success,
    required String conversationTitle,
    String? preview,
    bool cancelled = false,
  }) async {
    if (!_sessions.remove(sessionId ?? 'legacy')) return;
    final revision = ++_revision;
    if (!_generating) await _keepAlive.stop();
    if (kIsWeb) return;

    if (revision != _revision || cancelled || !_inBackground) return;
    await init();
    if (!_ready || revision != _revision || !_inBackground) return;
    // Permission dialogs cannot be shown in the background; start requested it.

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
            icon: '@drawable/ic_stat_notify',
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
