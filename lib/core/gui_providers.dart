import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';
import '../data/backup_journal.dart';
import '../data/full_backup_service.dart';
import '../domain/host/host_client.dart';
import '../domain/host/backup_client.dart';
import '../domain/cache/app_cache_service.dart';
import '../domain/memory/memory_backup_file.dart';
import '../domain/settings/settings_bundle_file.dart';
import '../domain/speech/mimo_speech_input_service.dart';
import '../domain/speech/speech_input_service.dart';
import '../domain/speech/fallback_text_to_speech_service.dart';
import '../domain/speech/system_text_to_speech_service.dart';
import '../domain/speech/text_to_speech_service.dart';

final fullBackupServiceProvider = Provider<FullBackupService>(
  (ref) => HostClient.current != null
      ? HostBackupService(
          ref.read(appDatabaseProvider),
          ref.read(libraryFileStoreProvider),
          ref.read(memoryStoreProvider),
          ref.read(sharedPrefsProvider),
          BackupJournal(),
        )
      : FullBackupService(
          ref.read(appDatabaseProvider),
          ref.read(libraryFileStoreProvider),
          ref.read(memoryStoreProvider),
          ref.read(sharedPrefsProvider),
          BackupJournal(),
        ),
);

final memoryBackupFileServiceProvider = Provider<MemoryBackupFileService>(
  (ref) => MemoryBackupFileService(),
);

final settingsBundleFileServiceProvider = Provider<SettingsBundleFileService>(
  (ref) => SettingsBundleFileService(),
);

final speechInputServiceProvider = Provider<SpeechInputService>(
  (ref) => SystemSpeechInputService(),
);

final mimoSpeechInputServiceProvider = Provider<MimoSpeechInputService>((ref) {
  final service = MimoSpeechInputService(
    mediaProvider: ref.read(mediaApiProvider),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final textToSpeechServiceProvider = Provider<TextToSpeechService>((ref) {
  final cloud = ApiTextToSpeechService(
    mediaProvider: ref.read(mediaApiProvider),
  );
  final TextToSpeechService service = kIsWeb
      ? cloud
      : FallbackTextToSpeechService(
          cloud: cloud,
          system: SystemTextToSpeechService(),
        );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final appCacheServiceProvider = Provider<AppCacheService>(
  (ref) => AppCacheService(),
);
