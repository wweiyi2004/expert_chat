import 'platform/theme_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'data/ui_prefs.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/conversation_return_scope.dart';
import 'features/shell/startup_error_app.dart';
import 'state/settings_controller.dart';
import 'features/tui_bridge/bridge_host.dart';
import 'core/host_client_bootstrap.dart';
import 'core/embedded_runtime_scope.dart';
import 'domain/runtime/embedded_runtime.dart';
import 'features/shell/host_connection_banner.dart';

Future<void> main(List<String> args) => launchApp(args);

/// Embedded execution is retained for mobile and explicit native test harnesses.
Future<void> launchApp(
  List<String> args, {
  bool embeddedTestRuntime = false,
}) async {
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
    if (!embeddedTestRuntime &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows) {
      final host = await HostClientBootstrap.open();
      runApp(host.wrap(const ExpertChatApp()));
      return;
    }
    final runtime = await EmbeddedRuntime.open();
    runApp(
      EmbeddedRuntimeScope(
        runtime: runtime,
        child: TuiBridgeHost(
          enabled: args.contains('--tui-bridge'),
          child: const ExpertChatApp(),
        ),
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
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _routeObserver = ConversationRouteObserver();
  UiPrefs? _themeUi;
  VisualDensity? _themeDensity;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;

  @override
  Widget build(BuildContext context) {
    final (themeMode, ui) = ref.watch(
      settingsControllerProvider.select(
        (settings) => (
          settings.value?.themeMode ?? ThemePreference.system,
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
      navigatorKey: _navigatorKey,
      navigatorObservers: [_routeObserver],
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: ThemeMode.values[themeMode.index],
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(ui.textScale.scale)),
          child: HostConnectionBanner(
            child: ConversationReturnScope(
              navigatorKey: _navigatorKey,
              observer: _routeObserver,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
      home: const AppShell(),
    );
  }
}
