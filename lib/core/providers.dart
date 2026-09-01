import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/character_repository.dart';
import '../data/conversation_repository.dart';
import '../data/db/app_database.dart';
import '../data/library_file_store.dart';
import '../data/library_repository.dart';
import '../data/drift_conversation_repository.dart';
import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';
import '../data/study_repository.dart';
import '../data/world_info_repository.dart';
import '../domain/context/context_window_manager.dart';
import '../domain/cache/app_cache_service.dart';
import '../domain/llm/deepseek_balance_client.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/llm/long_task_gateway_client.dart';
import '../domain/llm/model_usage_store.dart';
import '../domain/gateway/gateway_client.dart';
import '../domain/gateway/gateway_auth_service.dart';
import '../domain/llm/routing_llm_provider.dart';
import '../domain/llm/usage_tracking_llm_provider.dart';
import '../domain/media/openai_compatible_media_provider.dart';
import '../domain/memory/memory_backup_file.dart';
import '../domain/settings/settings_bundle_file.dart';
import '../domain/memory/memory_candidate_service.dart';
import '../domain/memory/memory_transfer.dart';
import '../domain/speech/mimo_speech_input_service.dart';
import '../domain/speech/speech_input_service.dart';
import '../domain/speech/text_to_speech_service.dart';
import '../domain/document/document_service_client.dart';
import '../domain/tools/file_parser.dart';
import '../domain/tools/search_provider.dart';
import '../domain/tools/tool_engine.dart';

/// Overridden in [main] once SharedPreferences has been initialized.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPrefsProvider must be overridden'),
);

final secureStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => const FlutterSecureStorage(),
);

/// Overridden in [main] with a single shared [AppDatabase] instance (so the
/// JSON→drift migration can run against the same connection).
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Concrete drift repo — exposes [DriftConversationRepository.search].
final driftConversationRepositoryProvider =
    Provider<DriftConversationRepository>(
      (ref) => DriftConversationRepository(ref.read(appDatabaseProvider)),
    );

/// Interface used by the controllers (drift-backed).
final conversationRepositoryProvider = Provider<ConversationRepository>(
  (ref) => ref.read(driftConversationRepositoryProvider),
);

final characterRepositoryProvider = Provider<CharacterRepository>(
  (ref) => CharacterRepository(ref.read(appDatabaseProvider)),
);

final libraryFileStoreProvider = Provider<LibraryFileStore>(
  (ref) => LibraryFileStore(),
);

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(
    ref.read(appDatabaseProvider),
    ref.read(libraryFileStoreProvider),
  ),
);

final worldInfoRepositoryProvider = Provider<WorldInfoRepository>(
  (ref) => WorldInfoRepository(ref.read(appDatabaseProvider)),
);

final studyRepositoryProvider = Provider<StudyRepository>(
  (ref) => StudyRepository(
    ref.read(appDatabaseProvider),
    ref.read(sharedPrefsProvider),
  ),
);

final memoryStoreProvider = Provider<MemoryStore>(
  (ref) => MemoryFileStore(ref.read(sharedPrefsProvider)),
);

final memoryRepositoryProvider = Provider<MemoryRepository>(
  (ref) => MemoryRepository(ref.read(memoryStoreProvider)),
);

final modelUsageStoreProvider = Provider<ModelUsageStore>(
  (ref) => ModelUsageStore(ref.read(sharedPrefsProvider)),
);

class ModelUsageController extends Notifier<List<ModelUsageRecord>> {
  ModelUsageStore get _store => ref.read(modelUsageStoreProvider);

  @override
  List<ModelUsageRecord> build() => _store.records;

  void record(LlmConfig config, LlmUsage usage) {
    _store.record(endpoint: config.baseUrl, model: config.model, usage: usage);
    state = _store.records;
  }

  Future<void> clear({String? endpoint}) async {
    await _store.clear(endpoint: endpoint);
    state = _store.records;
  }

  ModelUsageRecord? find({required String endpoint, required String model}) =>
      _store.find(endpoint: endpoint, model: model);

  List<ModelUsageRecord> forEndpoint(String endpoint) =>
      _store.forEndpoint(endpoint);

  ModelUsageRecord totals({String? endpoint}) =>
      _store.totals(endpoint: endpoint);
}

final modelUsageControllerProvider =
    NotifierProvider<ModelUsageController, List<ModelUsageRecord>>(
      ModelUsageController.new,
    );

final llmProvider = Provider<LlmProvider>((ref) {
  final usageController = ref.read(modelUsageControllerProvider.notifier);
  return UsageTrackingLlmProvider(
    delegate: RoutingLlmProvider(),
    onUsage: usageController.record,
  );
});

final deepSeekBalanceClientProvider = Provider<DeepSeekBalanceClient>(
  (ref) => DeepSeekBalanceClient(),
);

final longTaskGatewayClientProvider = Provider<LongTaskGatewayClient>(
  (ref) => LongTaskGatewayClient(),
);

final gatewayClientProvider = Provider<GatewayClient>((ref) => GatewayClient());

final gatewayAuthServiceProvider = Provider<GatewayAuthService>(
  (ref) => GatewayAuthService(),
);

final memoryCandidateServiceProvider = Provider<MemoryCandidateService>(
  (ref) => MemoryCandidateService(ref.read(llmProvider)),
);

final memoryTransferServiceProvider = Provider<MemoryTransferService>(
  (ref) => const MemoryTransferService(),
);

final memoryBackupFileServiceProvider = Provider<MemoryBackupFileService>(
  (ref) => MemoryBackupFileService(),
);

final settingsBundleFileServiceProvider = Provider<SettingsBundleFileService>(
  (ref) => SettingsBundleFileService(),
);

final mediaApiProvider = Provider<OpenAiCompatibleMediaProvider>(
  (ref) => OpenAiCompatibleMediaProvider(),
);

final contextWindowManagerProvider = Provider<ContextWindowManager>(
  (ref) => const ContextWindowManager(),
);

final fileParserProvider = Provider<FileParser>((ref) => FileParser());

final documentServiceClientProvider = Provider<DocumentServiceClient>(
  (ref) => DocumentServiceClient(),
);

final speechInputServiceProvider = Provider<SpeechInputService>(
  (ref) => SystemSpeechInputService(),
);

/// Cloud ASR path used when a MiMo ASR endpoint is configured in settings.
final mimoSpeechInputServiceProvider = Provider<MimoSpeechInputService>((ref) {
  final service = MimoSpeechInputService(
    mediaProvider: ref.read(mediaApiProvider),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// One app-wide speaker: beginning a new message cleanly replaces any older
/// read-aloud operation, even when the user changes conversations.
final textToSpeechServiceProvider = Provider<TextToSpeechService>((ref) {
  final service = ApiTextToSpeechService(
    mediaProvider: ref.read(mediaApiProvider),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

typedef ToolEngineFactory =
    ToolEngine Function({
      required SearchBackend backend,
      required String apiKey,
    });

class ToolEnginePool {
  /// Cap cached engines so rotating search API keys cannot grow without bound.
  static const int maxEngines = 4;

  final engines = <_ToolEngineConfigKey, ToolEngine>{};

  ToolEngine create({required SearchBackend backend, required String apiKey}) {
    final key = _ToolEngineConfigKey(backend, apiKey.trim());
    final existing = engines[key];
    if (existing != null) {
      // Refresh LRU order: re-insert at end.
      engines.remove(key);
      engines[key] = existing;
      return existing;
    }
    while (engines.length >= maxEngines) {
      final oldest = engines.keys.first;
      engines.remove(oldest)?.clearCache();
    }
    final created = ToolEngine(
      HttpSearchProvider(backend: backend, apiKey: key.apiKey),
    );
    engines[key] = created;
    return created;
  }

  void clear() {
    for (final engine in engines.values) {
      engine.clearCache();
    }
    engines.clear();
  }
}

final toolEnginePoolProvider = Provider<ToolEnginePool>((ref) {
  final pool = ToolEnginePool();
  ref.onDispose(pool.clear);
  return pool;
});

final toolEngineFactoryProvider = Provider<ToolEngineFactory>((ref) {
  // Reuse an engine for each backend/key pair so the short-lived result cache
  // can help across turns without mixing providers.
  final pool = ref.watch(toolEnginePoolProvider);
  return ({required backend, required apiKey}) =>
      pool.create(backend: backend, apiKey: apiKey);
});

final appCacheServiceProvider = Provider<AppCacheService>(
  (ref) => AppCacheService(),
);

class _ToolEngineConfigKey {
  const _ToolEngineConfigKey(this.backend, this.apiKey);

  final SearchBackend backend;
  final String apiKey;

  @override
  bool operator ==(Object other) =>
      other is _ToolEngineConfigKey &&
      other.backend == backend &&
      other.apiKey == apiKey;

  @override
  int get hashCode => Object.hash(backend, apiKey);
}
