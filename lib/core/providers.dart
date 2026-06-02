import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/conversation_repository.dart';
import '../data/db/app_database.dart';
import '../data/drift_conversation_repository.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/llm/openai_compatible_provider.dart';
import '../domain/tools/file_parser.dart';

/// Overridden in [main] once SharedPreferences has been initialized.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPrefsProvider must be overridden'),
);

final secureStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => const FlutterSecureStorage(),
);

/// Overridden in [main] with a single shared [AppDatabase] instance (so the
/// JSON→drift migration can run against the same connection).
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) {
    final db = AppDatabase();
    ref.onDispose(db.close);
    return db;
  },
);

/// Concrete drift repo — exposes [DriftConversationRepository.search].
final driftConversationRepositoryProvider =
    Provider<DriftConversationRepository>(
  (ref) => DriftConversationRepository(ref.read(appDatabaseProvider)),
);

/// Interface used by the controllers (drift-backed).
final conversationRepositoryProvider = Provider<ConversationRepository>(
  (ref) => ref.read(driftConversationRepositoryProvider),
);

final llmProvider = Provider<LlmProvider>(
  (ref) => OpenAiCompatibleProvider(),
);

final fileParserProvider = Provider<FileParser>((ref) => FileParser());
