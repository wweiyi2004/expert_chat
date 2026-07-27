import 'package:flutter/foundation.dart';
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
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    // Flutter 3.44's Windows accessibility bridge can dereference a semantics
    // node whose parent is null while UI Automation clients (including some
    // IMEs) inspect a rapidly changing tree. The native crash is in
    // AccessibilityBridge::CreateRemoveReparentedNodesUpdate.
    //
    // Keep the Windows semantics tree disabled until the engine fixes that
    // null-parent path. Other platforms retain their normal accessibility
    // behavior. Remove this binding once the engine fix is available.
    _WindowsCrashWorkaroundBinding();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  // Do NOT init local notifications / request runtime permissions here.
  // Android OEMs crash when POST_NOTIFICATIONS is requested before an
  // Activity is resumed. GenerationNotify.init() runs after first frame
  // from AppShell instead.

  try {
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
                const Text(
                  '本地数据初始化出错。可尝试清除应用数据后重装，或把下面信息反馈给开发者。',
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText('$error'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
          data: mq.copyWith(textScaler: TextScaler.linear(ui.textScale.scale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const AppShell(),
    );
  }
}
