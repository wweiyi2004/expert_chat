import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Serializes platform work so a slow start cannot outlive a stop, or a slow
/// stop release the protection belonging to the next turn.
class GenerationKeepAlive {
  static const _channel = MethodChannel('expert_chat/generation');
  Future<void> _pending = Future<void>.value();

  Future<void> start() => _setActive(true);
  Future<void> stop() => _setActive(false);

  Future<void> _setActive(bool active) {
    return _pending = _pending.then((_) async {
      if (kIsWeb) return;
      try {
        if (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.windows) {
          // A screen wakelock alone does not keep background networking alive.
          await _channel.invokeMethod<void>(active ? 'start' : 'stop');
        } else {
          await WakelockPlus.toggle(enable: active);
        }
      } on MissingPluginException {
        // Tests and older native packages do not implement this channel.
      } catch (error) {
        // Foreground chat remains usable if Android refuses a start; one
        // failure must not poison cleanup or the next user-initiated turn.
        debugPrint('Generation background protection unavailable: $error');
      }
    });
  }
}
