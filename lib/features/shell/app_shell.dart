import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/workspace_layout.dart';
import '../../domain/update/update_ui.dart';
import '../chat/chat_page.dart';
import '../settings/settings_page.dart';
import '../story/studio_page.dart';
import 'shell_tab.dart';

/// Root chrome: 会话 / 创作 / 我的.
///
/// Phone: bottom [NavigationBar]. Wide: [NavigationRail].
/// [IndexedStack] preserves scroll position and draft input across switches.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const _destinations = [
    (icon: Icons.forum_outlined, selected: Icons.forum, label: '会话'),
    (icon: Icons.menu_book_outlined, selected: Icons.menu_book, label: '创作'),
    (icon: Icons.person_outline, selected: Icons.person, label: '我的'),
  ];

  @override
  void initState() {
    super.initState();
    // Best-effort: prompt only when a newer GitHub Release exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      checkForUpdatesOnLaunch(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(shellTabIndexProvider);
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail =
            constraints.maxWidth >= WorkspaceBreakpoints.shellRail;

        final stack = IndexedStack(
          index: index,
          children: const [
            ChatPage(),
            StudioPage(),
            SettingsPage(asRootTab: true),
          ],
        );

        if (useRail) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) =>
                      ref.read(shellTabIndexProvider.notifier).set(i),
                  labelType: NavigationRailLabelType.all,
                  backgroundColor: scheme.surfaceContainer.withValues(
                    alpha: 0.96,
                  ),
                  indicatorColor: scheme.primaryContainer.withValues(
                    alpha: 0.85,
                  ),
                  destinations: [
                    for (final d in _destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selected),
                        label: Text(d.label),
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
          );
        }

        return Scaffold(
          body: stack,
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) =>
                ref.read(shellTabIndexProvider.notifier).set(i),
            backgroundColor: scheme.surfaceContainer.withValues(alpha: 0.96),
            indicatorColor: scheme.primaryContainer.withValues(alpha: 0.85),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final d in _destinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: d.label,
                ),
            ],
          ),
        );
      },
    );
  }
}
