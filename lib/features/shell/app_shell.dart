import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/workspace_layout.dart';
import '../../domain/notify/generation_notify.dart';
import '../../domain/update/shorebird_ui.dart';
import '../../domain/update/update_ui.dart';
import '../../state/chat_controller.dart';
import '../../state/research_mode_fx.dart';
import '../../state/settings_controller.dart';
import '../chat/chat_page.dart';
import '../research/research_mode_ripple.dart';
import '../research/research_terminal_page.dart';
import '../settings/settings_page.dart';
import '../story/studio_page.dart';
import '../study/study_hub_page.dart';
import 'shell_tab.dart';

/// Root chrome: 会话 / [终端] / [学习] / [创作] / 设置.
///
/// Phone: bottom [NavigationBar]. Wide: a unified collapsible workspace and
/// conversation sidebar.
/// [IndexedStack] preserves scroll position and draft input across switches.
/// Terminal / 学习 / 创作 tabs are only present when their mode flags are enabled.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  final _shellKey = GlobalKey();
  bool _desktopSidebarExpanded = true;

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

  /// Fixed page order — never insert/remove middle slots when mode toggles,
  /// or Settings/Studio state (e.g. 能力分类) is recreated and jumps to 模型.
  static const _stackOrder = <ShellTab>[
    ShellTab.chat,
    ShellTab.terminal,
    ShellTab.study,
    ShellTab.studio,
    ShellTab.settings,
  ];

  Widget _pageFor(
    ShellTab tab, {
    required bool researchOn,
    required bool studyOn,
    required bool creationOn,
    required bool desktopShell,
  }) => switch (tab) {
    ShellTab.chat => ChatPage(desktopShell: desktopShell),
    // Only mount heavy tabs when their mode is on; other stack slots stay put.
    ShellTab.terminal =>
      researchOn ? const ResearchTerminalPage() : const SizedBox.shrink(),
    ShellTab.study => studyOn ? const StudyHubPage() : const SizedBox.shrink(),
    ShellTab.studio =>
      creationOn ? const StudioPage() : const SizedBox.shrink(),
    ShellTab.settings => const SettingsPage(asRootTab: true),
  };

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider).value;
    final researchOn = settings?.researchModeEnabled ?? false;
    final studyOn = settings?.studyModeEnabled ?? true;
    final creationOn = settings?.creationModeEnabled ?? true;
    final visible = ShellTab.visible(
      researchModeEnabled: researchOn,
      studyModeEnabled: studyOn,
      creationModeEnabled: creationOn,
    );
    final selected = ref.watch(shellTabProvider);
    final scheme = Theme.of(context).colorScheme;

    // Keep selection valid when mode flags hide the current tab.
    ref.listen(settingsControllerProvider, (prev, next) {
      final research = next.value?.researchModeEnabled ?? false;
      final study = next.value?.studyModeEnabled ?? true;
      final creation = next.value?.creationModeEnabled ?? true;
      final tabs = ShellTab.visible(
        researchModeEnabled: research,
        studyModeEnabled: study,
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

    final navIndex = visible.contains(selected) ? visible.indexOf(selected) : 0;
    final stackIndex = _stackOrder
        .indexOf(selected)
        .clamp(0, _stackOrder.length - 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= WorkspaceBreakpoints.shellRail;
        final stack = IndexedStack(
          index: stackIndex,
          children: [
            for (final tab in _stackOrder)
              KeyedSubtree(
                key: ValueKey(tab),
                child: _pageFor(
                  tab,
                  researchOn: researchOn,
                  studyOn: studyOn,
                  creationOn: creationOn,
                  desktopShell: useRail,
                ),
              ),
          ],
        );

        final scaffold = useRail
            ? Scaffold(
                body: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      width: _desktopSidebarExpanded ? 288 : 64,
                      child: _desktopSidebarExpanded
                          ? ChatWorkspaceSidebar(
                              asyncState: ref.watch(chatControllerProvider),
                              onCollapse: () => setState(
                                () => _desktopSidebarExpanded = false,
                              ),
                            )
                          : _CompactWorkspaceRail(
                              visible: visible,
                              selected: selected,
                              onExpand: () => setState(
                                () => _desktopSidebarExpanded = true,
                              ),
                              onSelect: (tab) =>
                                  ref.read(shellTabProvider.notifier).set(tab),
                              onNewChat: () {
                                ref
                                    .read(chatControllerProvider.notifier)
                                    .newConversation();
                                ref
                                    .read(shellTabProvider.notifier)
                                    .set(ShellTab.chat);
                              },
                            ),
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

class _CompactWorkspaceRail extends StatelessWidget {
  const _CompactWorkspaceRail({
    required this.visible,
    required this.selected,
    required this.onExpand,
    required this.onSelect,
    required this.onNewChat,
  });

  final List<ShellTab> visible;
  final ShellTab selected;
  final VoidCallback onExpand;
  final ValueChanged<ShellTab> onSelect;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.96),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            IconButton(
              tooltip: '展开侧边栏',
              onPressed: onExpand,
              icon: const Icon(Icons.menu_rounded),
            ),
            const SizedBox(height: 4),
            IconButton.filled(
              tooltip: '新对话',
              onPressed: onNewChat,
              icon: const Icon(Icons.add_rounded),
              style: IconButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
              ),
            ),
            const SizedBox(height: 12),
            for (final tab in visible.where((tab) => tab != ShellTab.settings))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: IconButton(
                  tooltip: tab.label,
                  isSelected: selected == tab,
                  onPressed: () => onSelect(tab),
                  icon: Icon(tab.icon),
                  selectedIcon: Icon(tab.selectedIcon),
                  style: IconButton.styleFrom(
                    backgroundColor: selected == tab
                        ? scheme.primaryContainer.withValues(alpha: 0.72)
                        : Colors.transparent,
                    foregroundColor: selected == tab
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const Spacer(),
            IconButton(
              tooltip: ShellTab.settings.label,
              isSelected: selected == ShellTab.settings,
              onPressed: () => onSelect(ShellTab.settings),
              icon: Icon(ShellTab.settings.icon),
              selectedIcon: Icon(ShellTab.settings.selectedIcon),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
