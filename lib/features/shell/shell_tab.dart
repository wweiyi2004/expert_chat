import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bottom / rail tab index for [AppShell]: 0 会话 · 1 创作 · 2 我的.
final shellTabIndexProvider =
    NotifierProvider<ShellTabIndex, int>(ShellTabIndex.new);

class ShellTabIndex extends Notifier<int> {
  @override
  int build() => 0;

  void set(int index) => state = index.clamp(0, 2);
}

void openShellTab(WidgetRef ref, int index) {
  ref.read(shellTabIndexProvider.notifier).set(index);
}
