import 'package:flutter/foundation.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Result of a Shorebird code-push check / download.
class ShorebirdPatchResult {
  const ShorebirdPatchResult({
    required this.available,
    required this.message,
    this.currentPatchNumber,
    this.downloaded = false,
    this.restartRequired = false,
    this.unsupported = false,
    this.failed = false,
  });

  final bool available;
  final String message;
  final int? currentPatchNumber;
  final bool downloaded;
  final bool restartRequired;

  /// True when the binary was not built with Shorebird (e.g. plain flutter run).
  final bool unsupported;

  /// True for a real check/download failure, rather than an unsupported build.
  final bool failed;
}

/// Thin wrapper around [ShorebirdUpdater] for UI call sites.
class ShorebirdPatchService {
  ShorebirdPatchService({ShorebirdUpdater? updater})
    : _updater = updater ?? ShorebirdUpdater();

  final ShorebirdUpdater _updater;

  bool get isAvailable => !kIsWeb && _updater.isAvailable;

  /// Current installed patch number, or null if base release / unavailable.
  Future<int?> currentPatchNumber() async {
    if (!isAvailable) return null;
    try {
      final patch = await _updater.readCurrentPatch();
      return patch?.number;
    } catch (_) {
      return null;
    }
  }

  /// Check for a patch; optionally download it (applied on next cold start).
  Future<ShorebirdPatchResult> check({bool download = true}) async {
    // Web / plain debug builds are not Shorebird-enabled.
    if (kIsWeb) {
      return const ShorebirdPatchResult(
        available: false,
        unsupported: true,
        message: 'Web 端不支持 Shorebird 代码补丁。',
      );
    }
    if (!_updater.isAvailable) {
      return const ShorebirdPatchResult(
        available: false,
        unsupported: true,
        message:
            '当前安装包未接入 Shorebird 引擎（例如用了 flutter run / 普通 flutter build）。'
            '请安装 shorebird release 生成的版本。',
      );
    }

    try {
      final current = await _updater.readCurrentPatch();
      final status = await _updater.checkForUpdate();

      if (status == UpdateStatus.unavailable) {
        return ShorebirdPatchResult(
          available: false,
          unsupported: true,
          currentPatchNumber: current?.number,
          message:
              '当前安装包未接入 Shorebird 引擎（例如用了 flutter run / 普通 flutter build）。'
              '请使用 shorebird release 打出的安装包，才能接收代码补丁。',
        );
      }

      if (status == UpdateStatus.upToDate) {
        return ShorebirdPatchResult(
          available: false,
          currentPatchNumber: current?.number,
          message: current == null
              ? '已是最新（基座版本，无补丁）。'
              : '已是最新（补丁 #${current.number}）。',
        );
      }

      if (status == UpdateStatus.restartRequired) {
        return ShorebirdPatchResult(
          available: false,
          restartRequired: true,
          currentPatchNumber: current?.number,
          message: '代码补丁已在本机就绪。请完全退出应用后重新打开以生效。',
        );
      }

      // outdated
      if (!download) {
        return ShorebirdPatchResult(
          available: true,
          currentPatchNumber: current?.number,
          message: '发现新的代码补丁，可下载（下次冷启动生效）。',
        );
      }

      await _updater.update();
      return ShorebirdPatchResult(
        available: true,
        downloaded: true,
        restartRequired: true,
        currentPatchNumber: current?.number,
        message: '代码补丁已下载。请完全退出应用后重新打开以生效。',
      );
    } catch (e) {
      return ShorebirdPatchResult(
        available: false,
        failed: true,
        message: 'Shorebird 检查失败：$e',
      );
    }
  }
}
