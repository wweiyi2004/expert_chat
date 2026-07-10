import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'data/db/app_database.dart';
import 'data/drift_conversation_repository.dart';
import 'data/legacy_conversation_migration.dart';
import 'features/chat/chat_page.dart';
import 'state/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  // Single shared DB instance; migrate the M1 JSON history into it once.
  final db = AppDatabase();
  final driftRepo = DriftConversationRepository(db);
  await migrateLegacyJsonToDrift(driftRepo);

  runApp(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        appDatabaseProvider.overrideWithValue(db),
      ],
      child: const ExpertChatApp(),
    ),
  );
}

class ExpertChatApp extends ConsumerWidget {
  const ExpertChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Theme mode reacts to settings; default to system while loading.
    final themeMode = ref
        .watch(settingsControllerProvider)
        .maybeWhen(data: (s) => s.themeMode, orElse: () => ThemeMode.system);

    return MaterialApp(
      title: 'Expert Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: const ChatPage(),
    );
  }
}
