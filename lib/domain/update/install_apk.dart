import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native bridge for Android in-app APK install (FileProvider + package installer).
class InstallApk {
  InstallApk._();

  static const _channel = MethodChannel('expert_chat/install');

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Device primary ABI, e.g. `arm64-v8a`, or null when unavailable.
  static Future<String?> primaryAbi() async {
    if (!isAndroid) return null;
    try {
      final abi = await _channel.invokeMethod<String>('primaryAbi');
      return abi?.trim().isEmpty == true ? null : abi;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> canRequestPackageInstalls() async {
    if (!isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('canRequestPackageInstalls');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openUnknownAppSourcesSettings() async {
    if (!isAndroid) return;
    await _channel.invokeMethod<void>('openUnknownAppSources');
  }

  /// Opens the system package installer for [apkPath].
  static Future<void> install(String apkPath) async {
    if (!isAndroid) {
      throw UnsupportedError('APK install is only supported on Android');
    }
    await _channel.invokeMethod<void>('installApk', {'path': apkPath});
  }
}
