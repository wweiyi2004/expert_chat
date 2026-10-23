import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'data/db/app_database.dart';
import 'data/backup_journal.dart';
import 'data/full_backup_service.dart';
import 'data/library_file_store.dart';
import 'data/memory_file_store.dart';
import 'data/drift_conversation_repository.dart';
import 'data/legacy_conversation_migration.dart';
import 'data/study_repository.dart';
import 'data/ui_prefs.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/startup_error_app.dart';
import 'state/settings_controller.dart';

Future<void> main() async {
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows &&
      !const bool.fromEnvironment('EXPERT_CHAT_WINDOWS_SEMANTICS')) {
    // Flutter 3.44's Windows accessibility bridge can dereference a semantics
    // node whose parent is null while UI Automation clients (including some
    // IMEs) inspect a rapidly changing tree. The native crash is in
    // AccessibilityBridge::CreateRemoveReparentedNodesUpdate.
    //
    // Keep the Windows semantics tree disabled until the engine fixes that
    // null-parent path. Other platforms retain their normal accessibility
    // behavior. Remove this binding once the engine fix is available.
    //
    // Exit criteria and opt-in test build: docs/WINDOWS-ACCESSIBILITY.md.
    // Do not remove the guard based only on widget or synthetic UIA tests.
    _WindowsCrashWorkaroundBinding();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  // Do NOT init local notifications / request runtime permissions here.
  // Android OEMs crash when POST_NOTIFICATIONS is requested before an
  // Activity is resumed. GenerationNotify.init() runs after first frame
  // from AppShell instead.

  try {
    // Prefs I/O overlaps DB open; migration and study load are independent
    // of each other. Both still finish before runApp so controllers never
    // see a half-migrated store.
    final prefsFuture = SharedPreferences.getInstance();
    final db = AppDatabase();
    final prefs = await prefsFuture;
    await FullBackupService(
      db,
      LibraryFileStore(),
      MemoryFileStore(prefs),
      prefs,
      BackupJournal(),
    ).recoverPending();
    final driftRepo = DriftConversationRepository(db);
    await Future.wait([
      migrateLegacyJsonToDrift(driftRepo),
      StudyRepository(db, prefs).ensureMigrated(),
    ]);

    runApp(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
        ],
        child: const ExpertChatApp(),
      ),
    );
  } catch (e, st) {
    // Surface startup failures instead of a silent flash-exit.
    debugPrint('Expert Chat startup failed: $e\n$st');
    runApp(StartupErrorApp(error: e));
  }
}

class _WindowsCrashWorkaroundBinding extends WidgetsFlutterBinding {
  @override
  bool get semanticsEnabled => false;
}

class ExpertChatApp extends ConsumerStatefulWidget {
  const ExpertChatApp({super.key});

  @override
  ConsumerState<ExpertChatApp> createState() => _ExpertChatAppState();
}

class _ExpertChatAppState extends ConsumerState<ExpertChatApp> {
  UiPrefs? _themeUi;
  VisualDensity? _themeDensity;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;

  @override
  Widget build(BuildContext context) {
    final (themeMode, ui) = ref.watch(
      settingsControllerProvider.select(
        (settings) => (
          settings.value?.themeMode ?? ThemeMode.system,
          settings.value?.ui ?? const UiPrefs(),
        ),
      ),
    );
    final density = switch (ui.density) {
      DensityPref.spacious => VisualDensity.comfortable,
      DensityPref.comfortable => VisualDensity.standard,
      DensityPref.compact => VisualDensity.compact,
    };
    if (_lightTheme == null ||
        _darkTheme == null ||
        _themeUi == null ||
        _themeUi!.colorTheme != ui.colorTheme ||
        _themeUi!.cornerStyle != ui.cornerStyle ||
        _themeUi!.chatSurface != ui.chatSurface ||
        _themeUi!.lineHeight != ui.lineHeight ||
        _themeUi!.paragraphSpacing != ui.paragraphSpacing ||
        _themeUi!.messageSpacing != ui.messageSpacing ||
        _themeUi!.popoverMaxHeight != ui.popoverMaxHeight ||
        _themeUi!.popoverTopMargin != ui.popoverTopMargin ||
        _themeDensity != density) {
      _themeUi = ui;
      _themeDensity = density;
      _lightTheme = AppTheme.light(ui).copyWith(visualDensity: density);
      _darkTheme = AppTheme.dark(ui).copyWith(visualDensity: density);
    }

    return MaterialApp(
      title: 'Expert Chat',
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: themeMode,
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(ui.textScale.scale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const AppShell(),
    );
  }
}
