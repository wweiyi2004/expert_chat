import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'data/db/app_database.dart';
import 'data/drift_conversation_repository.dart';
import 'data/legacy_conversation_migration.dart';
import 'data/study_repository.dart';
import 'data/ui_prefs.dart';
import 'features/shell/app_shell.dart';
import 'state/settings_controller.dart';

Future<void> main() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    // Flutter 3.44's Windows accessibility bridge can dereference a semantics
    // node whose parent is null while UI Automation clients (including some
    // IMEs) inspect a rapidly changing tree. The native crash is in
    // AccessibilityBridge::CreateRemoveReparentedNodesUpdate.
    //
    // Keep the Windows semantics tree disabled until the engine fixes that
    // null-parent path. Other platforms retain their normal accessibility
    // behavior. Remove this binding once the engine fix is available.
    //
    // Track: https://github.com/flutter/flutter/issues (search
    // CreateRemoveReparentedNodesUpdate / Windows UIA). Re-enable semantics
    // after upgrading past a fixed Flutter engine and verifying with Narrator.
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
    final driftRepo = DriftConversationRepository(db);
    await Future.wait([
      migrateLegacyJsonToDrift(driftRepo),
      StudyRepository(db, prefs).load(),
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
    runApp(_StartupErrorApp(error: e));
  }
}

class _WindowsCrashWorkaroundBinding extends WidgetsFlutterBinding {
  @override
  bool get semanticsEnabled => false;
}

/// Shown only when prefs/DB bootstrap throws — better than a silent crash.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '启动失败',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text('本地数据初始化出错。可尝试清除应用数据后重装，或把下面信息反馈给开发者。'),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(child: SelectableText('$error')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
    final settings = ref.watch(settingsControllerProvider);
    final themeMode = settings.maybeWhen(
      data: (s) => s.themeMode,
      orElse: () => ThemeMode.system,
    );
    final ui = settings.maybeWhen(
      data: (s) => s.ui,
      orElse: () => const UiPrefs(),
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
        _themeDensity != density) {
      _themeUi = ui;
      _themeDensity = density;
      _lightTheme = AppTheme.light(ui).copyWith(visualDensity: density);
      _darkTheme = AppTheme.dark(ui).copyWith(visualDensity: density);
    }

    return MaterialApp(
      title: 'Expert Chat',
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
