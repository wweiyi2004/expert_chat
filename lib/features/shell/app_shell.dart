import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/workspace_layout.dart';
import '../../core/desktop_providers.dart';
import '../../state/conversation_workspace_bindings.dart';
import '../../domain/notify/generation_notify.dart';
import '../../domain/share/shared_intake.dart';
import '../../domain/update/shorebird_ui.dart';
import '../../domain/update/update_ui.dart';
import '../../state/chat_controller.dart';
import '../../state/research_mode_fx.dart';
import '../../state/settings_controller.dart';
import '../chat/chat_page.dart';
import '../chat/pending_share.dart';
import '../research/research_mode_ripple.dart';
import '../research/research_terminal_page.dart';
import '../settings/settings_page.dart';
import '../story/studio_page.dart';
import '../study/study_hub_page.dart';
import 'shell_tab.dart';
import 'tools_page.dart';
import 'desktop_navigation_rail.dart';

/// Root chrome: 会话 / 工具 / 设置.
///
/// Phone: navigation drawer. Wide: a unified collapsible workspace and
/// conversation sidebar.
/// [IndexedStack] preserves scroll position and draft input across switches.
/// Optional pages live under 工具 and mount only while their saved flag is on.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  final _shellKey = GlobalKey();
  final _pagesKey = GlobalKey();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _desktopSidebarExpanded = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(shellTabProvider, (previous, next) {
      // Provider changes can originate in a popup dismissal or a layout pass.
      scheduleMicrotask(() {
        if (mounted) {
          ref
              .read(chatControllerProvider.notifier)
              .reportChatVisible(next == ShellTab.chat);
        }
      });
    });
    // Best-effort OTA + notifications after the first frame (Activity ready).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Before the OTA delay so a share that launched the app opens promptly.
      unawaited(SharedIntake.listen(_openShared));
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

  /// Opens a new conversation for content shared from another app. The
  /// composer is filled by [ChatPage]; nothing is sent automatically.
  Future<void> _openShared(SharedPayload payload) async {
    await ref.read(chatControllerProvider.future);
    if (!mounted) return;
    ref.read(chatControllerProvider.notifier).newConversation();
    ref.read(shellTabProvider.notifier).set(ShellTab.chat);
    ref.read(pendingSharedPayloadProvider.notifier).set(payload);
  }

  @override
  void dispose() {
    SharedIntake.stop();
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
    ref.read(chatControllerProvider.notifier).reportAppBackground(background);
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
    ShellTab.tools,
  ];

  Widget _pageFor(
    ShellTab tab, {
    required bool researchOn,
    required bool studyOn,
    required bool creationOn,
    required bool desktopShell,
  }) => switch (tab) {
    ShellTab.chat => ChatPage(desktopShell: desktopShell),
    ShellTab.tools => ToolsPage(
      onOpenNavigation: desktopShell
          ? null
          : () => _scaffoldKey.currentState?.openDrawer(),
    ),
    // Only mount heavy tabs when their mode is on; other stack slots stay put.
    ShellTab.terminal =>
      researchOn
          ? ResearchTerminalPage(onBack: _backToTools)
          : const SizedBox.shrink(),
    ShellTab.study =>
      studyOn ? StudyHubPage(onBack: _backToTools) : const SizedBox.shrink(),
    ShellTab.studio =>
      creationOn ? StudioPage(onBack: _backToTools) : const SizedBox.shrink(),
    ShellTab.settings => SettingsPage(
      asRootTab: true,
      onOpenNavigation: desktopShell
          ? null
          : () => _scaffoldKey.currentState?.openDrawer(),
    ),
  };

  void _backToTools() =>
      ref.read(shellTabProvider.notifier).set(ShellTab.tools);

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

    final stackIndex = _stackOrder
        .indexOf(selected)
        .clamp(0, _stackOrder.length - 1);

    return PopScope(
      canPop: selected.navigationTab == selected,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && selected.navigationTab != selected) _backToTools();
      },
      // Shell fills the app viewport. Resolve this breakpoint during build,
      // not LayoutBuilder.performLayout: moving the preserved pages across
      // desktop/mobile parents can reactivate a live tooltip overlay.
      child: Builder(
        builder: (context) {
          final useRail =
              MediaQuery.sizeOf(context).width >=
              WorkspaceBreakpoints.shellRail;
          final stack = KeyedSubtree(
            key: _pagesKey,
            child: IndexedStack(
              index: stackIndex,
              children: [
                for (final tab in _stackOrder)
                  KeyedSubtree(
                    key: ValueKey(tab),
                    child: ExcludeFocus(
                      excluding: tab != selected,
                      child: _pageFor(
                        tab,
                        researchOn: researchOn,
                        studyOn: studyOn,
                        creationOn: creationOn,
                        desktopShell: useRail,
                      ),
                    ),
                  ),
              ],
            ),
          );

          final desktopTheme = desktopWorkspaceTheme(Theme.of(context));
          final scaffold = useRail
              ? Theme(
                  data: desktopTheme,
                  child: Scaffold(
                    backgroundColor: desktopTheme.colorScheme.surfaceContainer,
                    body: Row(
                      children: [
                        DesktopNavigationRail(
                          visible: visible,
                          selected: selected,
                          sidebarExpanded: _desktopSidebarExpanded,
                          onExpand: () =>
                              setState(() => _desktopSidebarExpanded = true),
                          onSelect: (tab) =>
                              ref.read(shellTabProvider.notifier).set(tab),
                          onNewChat: () async {
                            final controller = ref.read(
                              chatControllerProvider.notifier,
                            );
                            controller.newConversation();
                            final id = ref
                                .read(chatControllerProvider)
                                .value
                                ?.currentId;
                            try {
                              if (id != null &&
                                  ref
                                      .read(desktopWorkspaceHostProvider)
                                      .supported) {
                                await ref
                                    .read(
                                      conversationWorkspaceBindingsProvider
                                          .notifier,
                                    )
                                    .select(id, null);
                              }
                              if (!mounted ||
                                  ref
                                          .read(chatControllerProvider)
                                          .value
                                          ?.currentId !=
                                      id) {
                                return;
                              }
                              ref
                                  .read(shellTabProvider.notifier)
                                  .set(ShellTab.chat);
                            } catch (error) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('新会话未完成：$error')),
                                );
                              }
                            }
                          },
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(0, 8, 10, 10),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: desktopTheme.colorScheme.surface,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color:
                                      desktopTheme.colorScheme.outlineVariant,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: Row(
                                  children: [
                                    if (_desktopSidebarExpanded) ...[
                                      SizedBox(
                                        width: 264,
                                        child: ChatWorkspaceSidebar(
                                          desktopMode: true,
                                          onCollapse: () => setState(
                                            () =>
                                                _desktopSidebarExpanded = false,
                                          ),
                                        ),
                                      ),
                                      VerticalDivider(
                                        width: 1,
                                        color: desktopTheme
                                            .colorScheme
                                            .outlineVariant,
                                      ),
                                    ],
                                    Expanded(child: stack),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              // On the research terminal tab, do not shrink the body for the
              // soft keyboard — nested Scaffold + IME otherwise collapses the
              // terminal Expanded to 0 height (blank/white screen on dismiss).
              : Scaffold(
                  resizeToAvoidBottomInset: selected != ShellTab.terminal,
                  body: stack,
                  key: _scaffoldKey,
                  drawer: const Drawer(child: ChatWorkspaceSidebar()),
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
      ),
    );
  }
}
