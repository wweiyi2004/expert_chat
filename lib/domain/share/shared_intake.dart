import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One file another app shared, already copied into the app cache by
/// `SharedIntake.kt` so it can be read like a picked file.
@immutable
class SharedFile {
  const SharedFile({required this.path, required this.name, this.size});

  final String path;
  final String name;
  final int? size;
}

/// Content from an Android share sheet (ACTION_SEND / ACTION_SEND_MULTIPLE).
///
/// Skip counts come from the native copy step, which drops files over the
/// per-file limit or beyond the attachment count before touching Dart.
@immutable
class SharedPayload {
  const SharedPayload({
    this.text = '',
    this.files = const [],
    this.tooLarge = 0,
    this.tooMany = 0,
    this.unreadable = 0,
  });

  factory SharedPayload.fromMap(Map<Object?, Object?> map) {
    int count(String key) => (map[key] as num?)?.toInt() ?? 0;
    final files = <SharedFile>[
      for (final raw in (map['files'] as List<Object?>? ?? const []))
        if (raw is Map &&
            raw['path'] is String &&
            (raw['path'] as String).isNotEmpty)
          SharedFile(
            path: raw['path'] as String,
            name: (raw['name'] as String?) ?? '',
            size: (raw['size'] as num?)?.toInt(),
          ),
    ];
    return SharedPayload(
      text: ((map['text'] as String?) ?? '').trim(),
      files: files,
      tooLarge: count('tooLarge'),
      tooMany: count('tooMany'),
      unreadable: count('unreadable'),
    );
  }

  final String text;
  final List<SharedFile> files;
  final int tooLarge;
  final int tooMany;
  final int unreadable;

  int get skipped => tooLarge + tooMany + unreadable;

  bool get isEmpty => text.isEmpty && files.isEmpty && skipped == 0;
}

/// Native bridge for content shared into the app (Android only).
///
/// Native only signals `shareAvailable`; Dart always pulls with `takeShare`,
/// which also covers the share that cold-started the app.
class SharedIntake {
  SharedIntake._();

  static const channel = MethodChannel('expert_chat/share');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Starts delivering shares to [onShare], including a pending cold-start
  /// share. Calling again replaces the previous listener.
  static Future<void> listen(void Function(SharedPayload) onShare) async {
    if (!isSupported) return;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'shareAvailable') return;
      final payload = await take();
      if (payload != null) onShare(payload);
    });
    final initial = await take();
    if (initial != null) onShare(initial);
  }

  static void stop() {
    if (!isSupported) return;
    channel.setMethodCallHandler(null);
  }

  /// Takes (and clears) the pending share, or null when there is none.
  static Future<SharedPayload?> take() async {
    if (!isSupported) return null;
    try {
      final raw = await channel.invokeMapMethod<Object?, Object?>('takeShare');
      if (raw == null) return null;
      final payload = SharedPayload.fromMap(raw);
      return payload.isEmpty ? null : payload;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('SharedIntake.take failed: $error');
      return null;
    }
  }
}
