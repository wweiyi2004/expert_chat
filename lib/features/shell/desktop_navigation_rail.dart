import 'package:flutter/material.dart';
import 'shell_tab.dart';

/// Desktop-only global navigation. Project and conversation navigation lives
/// in the adjacent sidebar and can collapse without changing the page tree.
class DesktopNavigationRail extends StatelessWidget {
  const DesktopNavigationRail({
    super.key,
    required this.visible,
    required this.selected,
    required this.sidebarExpanded,
    required this.onSelect,
    required this.onExpand,
    required this.onNewChat,
  });
  final List<ShellTab> visible;
  final ShellTab selected;
  final bool sidebarExpanded;
  final ValueChanged<ShellTab> onSelect;
  final VoidCallback onExpand;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 64,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    for (final tab in visible.where(
                      (t) => t != ShellTab.settings,
                    ))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: IconButton(
                          key: ValueKey('desktop-nav-${tab.name}'),
                          tooltip: tab.label,
                          onPressed: () => onSelect(tab),
                          isSelected: selected == tab,
                          icon: Icon(
                            tab == ShellTab.chat
                                ? Icons.home_outlined
                                : tab.icon,
                            size: 22,
                          ),
                          selectedIcon: Icon(
                            tab == ShellTab.chat
                                ? Icons.home_rounded
                                : tab.selectedIcon,
                            size: 22,
                          ),
                          style: IconButton.styleFrom(
                            minimumSize: const Size.square(44),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            backgroundColor: selected == tab
                                ? colors.surfaceContainerHighest
                                : Colors.transparent,
                            foregroundColor: selected == tab
                                ? colors.onSurface
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (!sidebarExpanded) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 8,
                        ),
                        child: Divider(),
                      ),
                      IconButton(
                        tooltip: '展开侧边栏',
                        onPressed: onExpand,
                        icon: const Icon(Icons.view_sidebar_outlined),
                      ),
                      IconButton(
                        tooltip: '新对话',
                        onPressed: onNewChat,
                        icon: const Icon(Icons.edit_square),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('desktop-nav-settings'),
              tooltip: '设置',
              onPressed: () => onSelect(ShellTab.settings),
              icon: const Icon(Icons.settings_outlined),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

ThemeData desktopWorkspaceTheme(ThemeData base) {
  return base.copyWith(
    appBarTheme: base.appBarTheme.copyWith(
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
  );
}
