import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/workspace_layout.dart';
import '../../domain/notify/generation_notify.dart';
import '../../domain/update/shorebird_ui.dart';
import '../../domain/update/update_ui.dart';
import '../../state/research_mode_fx.dart';
import '../../state/settings_controller.dart';
import '../chat/chat_page.dart';
import '../research/research_mode_ripple.dart';
import '../research/research_terminal_page.dart';
import '../settings/settings_page.dart';
import '../story/studio_page.dart';
import 'shell_tab.dart';

/// Root chrome: 会话 / [终端] / [创作] / 设置.
///
/// Phone: bottom [NavigationBar]. Wide: [NavigationRail].
/// [IndexedStack] preserves scroll position and draft input across switches.
/// Terminal / 创作 tabs are only present when their mode flags are enabled.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  final _shellKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Best-effort OTA + notifications after the first frame (Activity ready).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Init only — no runtime permission dialogs before UI is alive.
      await GenerationNotify.init();
      // Stagger so the first frame paints before network work.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      await checkForUpdatesOnLaunch(context);
      if (!mounted) return;
      await checkShorebirdPatchOnLaunch(context);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Track background so completed generations can raise a local notification.
    final background =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    GenerationNotify.setAppBackground(background);
    if (state == AppLifecycleState.resumed) {
      // Continue OTA install if the user just granted unknown-sources permission.
      unawaited(resumePendingApkInstall());
    }
  }

  /// Fixed page order — never insert/remove middle slots when research toggles,
  /// or Settings/Studio state (e.g. 能力分类) is recreated and jumps to 模型.
  static const _stackOrder = <ShellTab>[
    ShellTab.chat,
    ShellTab.terminal,
    ShellTab.studio,
    ShellTab.settings,
  ];

  Widget _pageFor(
    ShellTab tab, {
    required bool researchOn,
    required bool creationOn,
  }) => switch (tab) {
    ShellTab.chat => const ChatPage(),
    // Only mount heavy tabs when their mode is on; other stack slots stay put.
    ShellTab.terminal => researchOn
        ? const ResearchTerminalPage()
        : const SizedBox.shrink(),
    ShellTab.studio => creationOn
        ? const StudioPage()
        : const SizedBox.shrink(),
    ShellTab.settings => const SettingsPage(asRootTab: true),
  };

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider).value;
    final researchOn = settings?.researchModeEnabled ?? false;
    final creationOn = settings?.creationModeEnabled ?? true;
    final visible = ShellTab.visible(
      researchModeEnabled: researchOn,
      creationModeEnabled: creationOn,
    );
    final selected = ref.watch(shellTabProvider);
    final scheme = Theme.of(context).colorScheme;

    // Keep selection valid when mode flags hide the current tab.
    ref.listen(settingsControllerProvider, (prev, next) {
      final research = next.value?.researchModeEnabled ?? false;
      final creation = next.value?.creationModeEnabled ?? true;
      final tabs = ShellTab.visible(
        researchModeEnabled: research,
        creationModeEnabled: creation,
      );
      ref.read(shellTabProvider.notifier).ensureVisible(tabs);
    });

    final fx = ref.watch(researchModeFxProvider);
    Offset? localOrigin;
    if (fx.playing && fx.originGlobal != null) {
      final box = _shellKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        localOrigin = box.globalToLocal(fx.originGlobal!);
      }
    }

    final navIndex = visible.contains(selected)
        ? visible.indexOf(selected)
        : 0;
    final stackIndex = _stackOrder.indexOf(selected).clamp(
      0,
      _stackOrder.length - 1,
    );

    final stack = IndexedStack(
      index: stackIndex,
      children: [
        for (final tab in _stackOrder)
          KeyedSubtree(
            key: ValueKey(tab),
            child: _pageFor(
              tab,
              researchOn: researchOn,
              creationOn: creationOn,
            ),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= WorkspaceBreakpoints.shellRail;

        final scaffold = useRail
            ? Scaffold(
                body: Row(
                  children: [
                    NavigationRail(
                      selectedIndex: navIndex,
                      onDestinationSelected: (i) =>
                          ref.read(shellTabProvider.notifier).set(visible[i]),
                      labelType: NavigationRailLabelType.all,
                      backgroundColor: scheme.surfaceContainer.withValues(
                        alpha: 0.96,
                      ),
                      indicatorColor: scheme.primaryContainer.withValues(
                        alpha: 0.85,
                      ),
                      destinations: [
                        for (final tab in visible)
                          NavigationRailDestination(
                            icon: Icon(tab.icon),
                            selectedIcon: Icon(tab.selectedIcon),
                            label: Text(tab.label),
                          ),
                      ],
                    ),
                    VerticalDivider(
                      width: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.85),
                    ),
                    Expanded(child: stack),
                  ],
                ),
              )
            // On the research terminal tab, do not shrink the body for the
            // soft keyboard — nested Scaffold + IME otherwise collapses the
            // terminal Expanded to 0 height (blank/white screen on dismiss).
            : Scaffold(
                resizeToAvoidBottomInset: selected != ShellTab.terminal,
                body: stack,
                bottomNavigationBar: NavigationBar(
                  selectedIndex: navIndex,
                  onDestinationSelected: (i) =>
                      ref.read(shellTabProvider.notifier).set(visible[i]),
                  backgroundColor: scheme.surfaceContainer.withValues(
                    alpha: 0.96,
                  ),
                  indicatorColor: scheme.primaryContainer.withValues(
                    alpha: 0.85,
                  ),
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  destinations: [
                    for (final tab in visible)
                      NavigationDestination(
                        icon: Icon(tab.icon),
                        selectedIcon: Icon(tab.selectedIcon),
                        label: tab.label,
                      ),
                  ],
                ),
              );

        return KeyedSubtree(
          key: _shellKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              scaffold,
              ResearchModeRippleOverlay(
                playing: fx.playing,
                origin: localOrigin,
                onFinished: () {
                  ref.read(researchModeFxProvider.notifier).finish();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
