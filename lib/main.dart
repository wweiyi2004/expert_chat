import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'data/db/app_database.dart';
import 'data/drift_conversation_repository.dart';
import 'data/legacy_conversation_migration.dart';
import 'data/ui_prefs.dart';
import 'features/shell/app_shell.dart';
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
    final settings = ref.watch(settingsControllerProvider);
    final themeMode = settings.maybeWhen(
      data: (s) => s.themeMode,
      orElse: () => ThemeMode.system,
    );
    final ui = settings.maybeWhen(
      data: (s) => s.ui,
      orElse: () => const UiPrefs(),
    );
    final density = ui.density == DensityPref.compact
        ? VisualDensity.compact
        : VisualDensity.standard;

    return MaterialApp(
      title: 'Expert Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light().copyWith(visualDensity: density),
      darkTheme: AppTheme.dark().copyWith(visualDensity: density),
      themeMode: themeMode,
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(ui.textScale.scale),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const AppShell(),
    );
  }
}
