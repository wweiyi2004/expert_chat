import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/custom_tts_voices.dart';
import '../../data/media_api_config.dart';

/// Copies a bundled voice-pack sample into app support so clone mode can use
/// a stable absolute path (assets are not real filesystem paths at runtime).
class CustomTtsVoiceInstaller {
  /// Installs [pack]'s sample (if any) and returns a config ready for TTS.
  ///
  /// Prefer design mode when no sample is bundled or asset load fails — that
  /// still yields a strong anime-style voice via MiMo voicedesign.
  Future<MediaApiConfig> applyPack({
    required CustomTtsVoicePack pack,
    required MediaApiConfig current,
    CustomTtsVoiceApplyMode preferredMode = CustomTtsVoiceApplyMode.design,
  }) async {
    if (preferredMode == CustomTtsVoiceApplyMode.clone && pack.hasCloneSample) {
      final path = await installSample(pack);
      if (path != null) {
        return pack.applyTo(
          current,
          mode: CustomTtsVoiceApplyMode.clone,
          voiceClonePath: path,
        );
      }
    }
    // Design is the reliable default for persona packs.
    if (preferredMode == CustomTtsVoiceApplyMode.builtinStyle) {
      return pack.applyTo(current, mode: CustomTtsVoiceApplyMode.builtinStyle);
    }
    return pack.applyTo(current, mode: CustomTtsVoiceApplyMode.design);
  }

  /// Returns the absolute path of the installed sample, or null on failure.
  Future<String?> installSample(CustomTtsVoicePack pack) async {
    final asset = pack.sampleAssetPath?.trim();
    if (asset == null || asset.isEmpty) return null;
    try {
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (bytes.isEmpty) return null;

      final support = await getApplicationSupportDirectory();
      final dir = Directory(
        '${support.path}${Platform.pathSeparator}tts-voice-packs',
      );
      await dir.create(recursive: true);
      final name = pack.sampleFileName?.trim().isNotEmpty == true
          ? pack.sampleFileName!.trim()
          : '${pack.id}.mp3';
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
