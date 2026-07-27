import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/character_repository.dart';
import '../data/conversation_repository.dart';
import '../data/db/app_database.dart';
import '../data/drift_conversation_repository.dart';
import '../data/world_info_repository.dart';
import '../domain/context/context_window_manager.dart';
import '../domain/cache/app_cache_service.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/llm/openai_compatible_provider.dart';
import '../domain/media/openai_compatible_media_provider.dart';
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

final worldInfoRepositoryProvider = Provider<WorldInfoRepository>(
  (ref) => WorldInfoRepository(ref.read(appDatabaseProvider)),
);

final llmProvider = Provider<LlmProvider>((ref) => OpenAiCompatibleProvider());

final mediaApiProvider = Provider<OpenAiCompatibleMediaProvider>(
  (ref) => OpenAiCompatibleMediaProvider(),
);

final contextWindowManagerProvider = Provider<ContextWindowManager>(
  (ref) => const ContextWindowManager(),
);

final fileParserProvider = Provider<FileParser>((ref) => FileParser());

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
