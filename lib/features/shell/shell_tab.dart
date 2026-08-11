import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Semantic shell destinations. Order in [ShellTab.visible] depends on
/// research / creation / study mode flags — never hard-code indexes elsewhere.
enum ShellTab {
  chat,
  terminal,
  study,
  studio,
  settings;

  String get label => switch (this) {
    ShellTab.chat => '会话',
    ShellTab.terminal => '终端',
    ShellTab.study => '学习',
    ShellTab.studio => '创作',
    ShellTab.settings => '设置',
  };

  IconData get icon => switch (this) {
    ShellTab.chat => Icons.forum_outlined,
    ShellTab.terminal => Icons.terminal_rounded,
    ShellTab.study => Icons.school_outlined,
    ShellTab.studio => Icons.menu_book_outlined,
    ShellTab.settings => Icons.settings_outlined,
  };

  IconData get selectedIcon => switch (this) {
    ShellTab.chat => Icons.forum,
    ShellTab.terminal => Icons.terminal,
    ShellTab.study => Icons.school,
    ShellTab.studio => Icons.menu_book,
    ShellTab.settings => Icons.settings,
  };

  /// Visible tabs for the current mode flags.
  ///
  /// Order: 会话 → [终端] → [学习] → [创作] → 设置.
  static List<ShellTab> visible({
    required bool researchModeEnabled,
    bool studyModeEnabled = true,
    bool creationModeEnabled = true,
  }) => [
    ShellTab.chat,
    if (researchModeEnabled) ShellTab.terminal,
    if (studyModeEnabled) ShellTab.study,
    if (creationModeEnabled) ShellTab.studio,
    ShellTab.settings,
  ];
}

/// Currently selected shell tab (semantic, not a raw index).
final shellTabProvider = NotifierProvider<ShellTabController, ShellTab>(
  ShellTabController.new,
);

class ShellTabController extends Notifier<ShellTab> {
  @override
  ShellTab build() => ShellTab.chat;

  void set(ShellTab tab) => state = tab;

  /// Keep selection valid when the visible set changes (e.g. research off).
  void ensureVisible(List<ShellTab> visible) {
    if (!visible.contains(state)) {
      state = visible.contains(ShellTab.settings)
          ? ShellTab.settings
          : visible.first;
    }
  }
}

/// Open a shell tab by semantic identity.
///
/// Deferred to the next frame so callers inside [PopupMenuButton.onSelected]
/// (or other overlay dismissals) do not rebuild [IndexedStack] mid-layout,
/// which triggers `debugNeedsLayout is not true` red screens.
void openShellTab(WidgetRef ref, ShellTab tab) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ref.read(shellTabProvider.notifier).set(tab);
  });
}

/// Legacy name kept so older call sites compile during migration — prefer
/// [shellTabProvider].
@Deprecated('Use shellTabProvider')
final shellTabIndexProvider = shellTabProvider;
