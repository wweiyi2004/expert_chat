import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/character_repository.dart';
import '../data/conversation_repository.dart';
import '../data/db/app_database.dart';
import '../data/drift_conversation_repository.dart';
import '../data/world_info_repository.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/llm/openai_compatible_provider.dart';
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

final fileParserProvider = Provider<FileParser>((ref) => FileParser());

typedef ToolEngineFactory =
    ToolEngine Function({
      required SearchBackend backend,
      required String apiKey,
    });

final toolEngineFactoryProvider = Provider<ToolEngineFactory>((ref) {
  // The factory is called for each search step. Reuse an engine for each
  // backend/key pair so ToolEngine's short-lived result cache can help across
  // turns without mixing results from different configured providers.
  final engines = <_ToolEngineConfigKey, ToolEngine>{};
  ref.onDispose(engines.clear);
  return ({required backend, required apiKey}) {
    final key = _ToolEngineConfigKey(backend, apiKey.trim());
    return engines.putIfAbsent(
      key,
      () =>
          ToolEngine(HttpSearchProvider(backend: backend, apiKey: key.apiKey)),
    );
  };
});

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
