import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import '../../core/workspace_layout.dart';
import '../../data/research/research_prefs.dart';
import '../../data/research/ssh_profile.dart';
import '../../domain/research/command_risk.dart';
import '../../domain/research/research_copilot_service.dart';
import '../../domain/research/research_ssh_client.dart';
import '../../state/research_terminal_controller.dart';
import '../shell/shell_tab.dart';

/// M7 research terminal: SSH + tmux + AI command approval.
///
/// Expert Chat chrome stays paper/ink; only the terminal canvas is dark.
class ResearchTerminalPage extends ConsumerStatefulWidget {
  const ResearchTerminalPage({super.key});

  @override
  ConsumerState<ResearchTerminalPage> createState() =>
      _ResearchTerminalPageState();
}

class _ResearchTerminalPageState extends ConsumerState<ResearchTerminalPage>
    with WidgetsBindingObserver {
  final _termFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireHostKeyHandlers());
  }

  @override
  void dispose() {
    // Detach from the binding first. If the ref work below throws — the
    // container can already be torn down when a host disposes bottom-up — a
    // stranded observer would keep calling setState on a defunct element.
    WidgetsBinding.instance.removeObserver(this);
    _termFocus.dispose();
    // The controller outlives this page; a handler left bound would try to
    // show a dialog on a dead context the next time a host key needs approval.
    try {
      ref
          .read(researchTerminalProvider.notifier)
          .clearHostKeyHandlers(
            onTrust: _confirmHostKeyTrust,
            onMismatch: _confirmHostKeyMismatch,
          );
    } on Object {
      // Container already gone; the handlers died with it.
    }
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // After soft-keyboard open/close, force a layout pass so the terminal
    // Expanded does not stay at a stale zero height (mobile white screen).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _wireHostKeyHandlers() {
    if (!mounted) return;
    ref
        .read(researchTerminalProvider.notifier)
        .setHostKeyHandlers(
          onTrust: _confirmHostKeyTrust,
          onMismatch: _confirmHostKeyMismatch,
        );
  }

  Future<bool> _confirmHostKeyTrust(ResearchHostKeyInfo info) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.verified_user_outlined),
        title: const Text('信任此主机密钥？'),
        content: SingleChildScrollView(
          child: SelectableText(
            '首次连接需要确认服务器指纹，防止中间人攻击。\n\n'
            '类型：${info.keyType}\n'
            '指纹：\n${info.fingerprintSha256}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('信任并连接'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<bool> _confirmHostKeyMismatch(
    ResearchHostKeyInfo info,
    String previous,
  ) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.warning_amber_rounded,
          color: Theme.of(ctx).colorScheme.error,
        ),
        title: const Text('主机密钥已变化'),
        content: SingleChildScrollView(
          child: SelectableText(
            '保存的指纹与服务器当前密钥不一致。这可能是正常轮换，'
            '也可能是中间人攻击。\n\n'
            '已保存：\n$previous\n\n'
            '当前（${info.keyType}）：\n${info.fingerprintSha256}\n\n'
            '仅在你确认服务器密钥已合法更换后继续。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('中止'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仍要信任'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _showConnectionManager() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => const _ConnectionManagerSheet(),
    );
    if (mounted) _wireHostKeyHandlers();
  }

  Future<void> _connectActiveOrPick() async {
    final state = ref.read(researchTerminalProvider);
    final profile =
        state.activeProfile ??
        (state.profiles.isNotEmpty ? state.profiles.first : null);
    if (profile == null) {
      await _showConnectionManager();
      return;
    }
    _wireHostKeyHandlers();
    await ref.read(researchTerminalProvider.notifier).connect(profile);
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.link_off_outlined),
        title: const Text('断开 SSH？'),
        content: const Text('将关闭本机终端会话。远端 tmux 中的任务会继续运行。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(researchTerminalProvider.notifier).disconnect();
    }
  }

  Future<void> _newTmuxSession() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建 tmux 会话'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '会话名',
            helperText: '仅字母、数字、_ . : -',
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_.:-]')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await ref.read(researchTerminalProvider.notifier).createTmuxSession(name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('创建失败：$e')));
    }
  }

  Future<void> _showTmuxList() async {
    final ctrl = ref.read(researchTerminalProvider.notifier);
    await ctrl.refreshTmux();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) {
        final maxH = MediaQuery.sizeOf(ctx).height * 0.72;
        return SafeArea(
          child: SizedBox(
            height: maxH,
            child: Consumer(
              builder: (ctx, sheetRef, _) {
                final live = sheetRef.watch(researchTerminalProvider);
                final sessions = live.tmuxSessions;
                final err = live.tmuxError;
                final current = live.currentTmuxName;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      title: Text(
                        'tmux 会话',
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                      subtitle: const Text('点选即可切换，无需先分离'),
                      trailing: IconButton(
                        tooltip: '刷新',
                        onPressed: () => unawaited(ctrl.refreshTmux()),
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                    if (err != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          err,
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                      ),
                    Expanded(
                      child: sessions.isEmpty && err == null
                          ? const Center(child: Text('暂无 tmux 会话。可点 + 新建。'))
                          : ListView.builder(
                              itemCount: sessions.length,
                              itemBuilder: (_, i) {
                                final s = sessions[i];
                                final selected = s.name == current;
                                return ListTile(
                                  selected: selected,
                                  leading: Icon(
                                    s.attached > 0
                                        ? Icons.cast_connected
                                        : Icons.desktop_windows_outlined,
                                  ),
                                  title: Text(s.name),
                                  subtitle: Text(
                                    '${s.windows} 窗口 · attached=${s.attached}'
                                    '${selected ? ' · 当前' : ''}',
                                  ),
                                  trailing: selected
                                      ? const Icon(Icons.check_circle_outline)
                                      : const Icon(Icons.swap_horiz),
                                  onTap: () async {
                                    Navigator.of(ctx).pop();
                                    await ctrl.switchTmuxSession(s.name);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _sendShortcut(String raw) {
    // The Ctrl latch lives in the controller so the soft keyboard — whose text
    // reaches the PTY through terminal.onOutput, never through this method —
    // gets the modifier applied too.
    final blocked = ref
        .read(researchTerminalProvider.notifier)
        .writeUserInput(raw);
    if (blocked && mounted) _showInterruptBlockedSnack();
  }

  void _showInterruptBlockedSnack() {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('已拦截中断键，避免误杀远端进程（可在终端栏关闭「拦截 Ctrl+C」）'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    ref.read(researchTerminalProvider.notifier).clearInterruptBlockedFlash();
  }

  Future<void> _confirmSendCtrlC() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.warning_amber_rounded,
          color: Theme.of(ctx).colorScheme.error,
        ),
        title: const Text('发送 Ctrl+C？'),
        content: const Text(
          '这会中断远端当前前台进程。若正在观察长时间训练，请不要发送。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仍要发送'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      ref.read(researchTerminalProvider.notifier).sendCtrlCForced();
    }
  }

  Future<void> _openAiSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.74,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scroll) => _AiAssistPanel(scrollController: scroll),
      ),
    );
    // Closing the sheet invalidates pending proposal UX; clear for safety.
    if (mounted) {
      ref.read(researchTerminalProvider.notifier).clearProposal();
    }
  }

  @override
  Widget build(BuildContext context) {
    // ref.watch/ref.listen must run in this build, not in the LayoutBuilder
    // callback below — Riverpod asserts on the enclosing element being mid-build.
    final state = ref.watch(researchTerminalProvider);
    final ctrl = ref.read(researchTerminalProvider.notifier);

    // Keyboard interrupt blocked via terminal.onOutput — surface a snack once.
    ref.listen(researchTerminalProvider, (prev, next) {
      if (next.interruptBlockedFlash && prev?.interruptBlockedFlash != true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showInterruptBlockedSnack();
        });
      }
    });

    // This page is hosted inside the shell Scaffold's body, which on phones
    // sits above a NavigationBar. viewInsets are measured from the screen edge,
    // so anything positioned against the IME first needs to know how far this
    // page's bottom edge already is from the screen's.
    return LayoutBuilder(
      builder: (context, constraints) {
        final bottomGap = constraints.maxHeight.isFinite
            ? math.max(
                0.0,
                MediaQuery.sizeOf(context).height - constraints.maxHeight,
              )
            : 0.0;
        return _buildPage(
          context,
          state: state,
          ctrl: ctrl,
          bottomGap: bottomGap,
        );
      },
    );
  }

  Widget _buildPage(
    BuildContext context, {
    required ResearchTerminalState state,
    required ResearchTerminalController ctrl,
    required double bottomGap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final profile = state.activeProfile;
    final wide =
        MediaQuery.sizeOf(context).width >= WorkspaceBreakpoints.shellRail;

    // The slice of keyboard that actually covers this page — the rest of it is
    // behind the shell's NavigationBar, which the IME hides anyway.
    final keyboardOverlap = math.max(
      0.0,
      MediaQuery.viewInsetsOf(context).bottom - bottomGap,
    );
    final keyboardOpen = keyboardOverlap > 0;

    final shortcutBar = state.isConnected
        ? _ShortcutBar(
            ctrlLatched: state.ctrlLatched,
            onToggleCtrl: () => ctrl.setCtrlLatched(!state.ctrlLatched),
            onSend: _sendShortcut,
            // Floating above the IME already clears the system gesture bar.
            bottomSafeArea: !keyboardOpen,
            // The wide layout docks the assistant on the right instead.
            onOpenAi: wide ? null : () => unawaited(_openAiSheet()),
          )
        : null;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TmuxSessionBar(
          state: state,
          onNew: state.isConnected ? _newTmuxSession : null,
          onList: state.isConnected ? _showTmuxList : null,
          onRefresh: state.isConnected
              ? () => unawaited(ctrl.refreshTmux())
              : null,
          onDetach: state.isConnected && state.currentTmuxName != null
              ? () => unawaited(ctrl.detachTmuxSession())
              : null,
          onToggleBlockCtrlC: state.isConnected
              ? (v) => unawaited(ctrl.setBlockCtrlC(v))
              : null,
          onForceCtrlC: state.isConnected ? _confirmSendCtrlC : null,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF1A222D),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: state.isConnected
                    ? LayoutBuilder(
                        builder: (context, constraints) {
                          // Keep a paint surface even if parent briefly reports
                          // a tiny height during IME animation.
                          final h = constraints.maxHeight.isFinite
                              ? constraints.maxHeight
                              : 120.0;
                          return SizedBox(
                            width: constraints.maxWidth,
                            height: h < 48 ? 48 : h,
                            child: TerminalView(
                              ctrl.terminal,
                              focusNode: _termFocus,
                              autofocus: false,
                              backgroundOpacity: 1,
                              theme: TerminalThemes.defaultTheme,
                              textStyle: const TerminalStyle(
                                fontSize: 13,
                                fontFamily: 'Cascadia Mono',
                                fontFamilyFallback: [
                                  'Consolas',
                                  'Courier New',
                                  'monospace',
                                ],
                              ),
                              padding: const EdgeInsets.all(8),
                            ),
                          );
                        },
                      )
                    : _DisconnectedPane(
                        web: kIsWeb,
                        status: state.status,
                        message: state.statusMessage,
                        profile: profile,
                        onConnect: kIsWeb ? null : _connectActiveOrPick,
                        onManage: kIsWeb ? null : _showConnectionManager,
                      ),
              ),
            ),
          ),
        ),
        // While the IME is up the strip is re-hosted above the keyboard (see
        // below): resizeToAvoidBottomInset is off, so in flow it would sit
        // behind the keyboard rather than free vertical space.
        if (shortcutBar != null && !keyboardOpen) shortcutBar,
      ],
    );

    // Ctrl only means anything paired with a letter, and on a phone the letters
    // come from the soft keyboard — so the strip has to stay reachable while
    // the keyboard is open. Overlaying keeps the terminal at full height, which
    // is what stops the canvas from blanking when the keyboard dismisses.
    final bodyWithBar = shortcutBar != null && keyboardOpen
        ? Stack(
            children: [
              Positioned.fill(child: body),
              Positioned(
                left: 0,
                right: 0,
                bottom: keyboardOverlap,
                child: shortcutBar,
              ),
            ],
          )
        : body;

    return Scaffold(
      // Critical on phones: do not shrink this page when the soft keyboard
      // opens — otherwise Expanded terminal height → 0 and the shell shows
      // empty surface (white/cream) after the keyboard dismisses.
      resizeToAvoidBottomInset: false,
      backgroundColor: scheme.surface,
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          children: [
            Icon(Icons.terminal_rounded, color: scheme.primary),
            const SizedBox(width: 8),
            const Flexible(child: Text('科研终端')),
          ],
        ),
        actions: [
          if (profile != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: _HostStatusChip(
                  hostLabel: profile.name.isNotEmpty
                      ? profile.name
                      : profile.host,
                  status: state.status,
                  latencyMs: state.latencyMs,
                ),
              ),
            ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) async {
              switch (v) {
                case 'manage':
                  await _showConnectionManager();
                case 'connect':
                  await _connectActiveOrPick();
                case 'disconnect':
                  await _disconnect();
                case 'detach':
                  await ref
                      .read(researchTerminalProvider.notifier)
                      .detachTmuxSession();
                case 'settings':
                  openShellTab(ref, ShellTab.settings);
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'manage', child: Text('连接管理')),
              if (!kIsWeb && !state.isConnected)
                const PopupMenuItem(value: 'connect', child: Text('连接')),
              if (state.isConnected)
                const PopupMenuItem(value: 'disconnect', child: Text('断开')),
              if (state.isConnected && state.currentTmuxName != null)
                const PopupMenuItem(
                  value: 'detach',
                  child: Text('分离 tmux（不停任务）'),
                ),
              const PopupMenuItem(value: 'settings', child: Text('科研模式设置')),
            ],
          ),
        ],
      ),
      // No FAB: an extended one floated over the right half of the shortcut
      // strip and swallowed the arrow keys. The assistant now lives at the
      // right end of that strip, where it also survives the IME being up.
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: bodyWithBar),
                VerticalDivider(
                  width: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.7),
                ),
                SizedBox(
                  width: 380,
                  child: _AiAssistPanel(
                    embedded: true,
                    onRequestAnalyze: () => unawaited(ctrl.analyzeWithAi()),
                  ),
                ),
              ],
            )
          : bodyWithBar,
    );
  }
}

class _HostStatusChip extends StatelessWidget {
  const _HostStatusChip({
    required this.hostLabel,
    required this.status,
    this.latencyMs,
  });

  final String hostLabel;
  final ResearchConnectionStatus status;
  final int? latencyMs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = switch (status) {
      ResearchConnectionStatus.connected => (
        const Color(0xFF2E7D4F),
        latencyMs != null ? '${latencyMs}ms' : '已连接',
      ),
      ResearchConnectionStatus.connecting => (scheme.tertiary, '连接中'),
      ResearchConnectionStatus.error => (scheme.error, '错误'),
      ResearchConnectionStatus.disconnected => (scheme.outline, '未连接'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              hostLabel,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _TmuxSessionBar extends StatelessWidget {
  const _TmuxSessionBar({
    required this.state,
    this.onNew,
    this.onList,
    this.onRefresh,
    this.onDetach,
    this.onToggleBlockCtrlC,
    this.onForceCtrlC,
  });

  final ResearchTerminalState state;
  final VoidCallback? onNew;
  final VoidCallback? onList;
  final VoidCallback? onRefresh;
  final VoidCallback? onDetach;
  final ValueChanged<bool>? onToggleBlockCtrlC;
  final VoidCallback? onForceCtrlC;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = state.currentTmuxName ?? 'shell';
    final inTmux = state.currentTmuxName != null;
    // Fixed-height bar + horizontal scroll avoids hover reflow flicker.
    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            Center(
              child: Icon(
                Icons.view_agenda_outlined,
                size: 18,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140, minWidth: 48),
                child: Text(
                  name,
                  style: Theme.of(context).textTheme.labelLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (state.tmuxError != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.info_outline,
                    size: 18,
                    color: scheme.error,
                  ),
                ),
              ),
            if (onDetach != null) ...[
              const SizedBox(width: 8),
              Center(
                child: TextButton.icon(
                  onPressed: onDetach,
                  icon: const Icon(Icons.logout, size: 16),
                  label: const Text('分离 tmux'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
            ] else if (inTmux) ...[
              // currentTmuxName set but no handler — still show label only.
            ],
            if (onToggleBlockCtrlC != null) ...[
              const SizedBox(width: 8),
              // Stable switch (not FilterChip): no selected-size/ink hover thrash.
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.8),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10, right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 16,
                          color: state.blockCtrlC
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '拦截 Ctrl+C',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        SizedBox(
                          height: 32,
                          child: Switch.adaptive(
                            value: state.blockCtrlC,
                            onChanged: onToggleBlockCtrlC,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        if (state.blockCtrlC && onForceCtrlC != null)
                          IconButton(
                            tooltip: '确认后强制发送 Ctrl+C',
                            onPressed: onForceCtrlC,
                            icon: const Icon(
                              Icons.front_hand_outlined,
                              size: 18,
                            ),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 4),
            IconButton(
              tooltip: '刷新 tmux',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh, size: 20),
            ),
            TextButton(
              onPressed: onList,
              child: Text('tmux ${state.tmuxSessions.length}'),
            ),
            IconButton(
              tooltip: '新建 tmux',
              onPressed: onNew,
              icon: const Icon(Icons.add, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShortcutBar extends StatelessWidget {
  const _ShortcutBar({
    required this.ctrlLatched,
    required this.onToggleCtrl,
    required this.onSend,
    required this.bottomSafeArea,
    this.onOpenAi,
  });

  final bool ctrlLatched;
  final VoidCallback onToggleCtrl;
  final ValueChanged<String> onSend;
  final bool bottomSafeArea;
  final VoidCallback? onOpenAi;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keys = <(String, String, VoidCallback?)>[
      ('Ctrl', '', onToggleCtrl),
      ('Esc', '\x1b', null),
      ('Tab', '\t', null),
      ('|', '|', null),
      ('~', '~', null),
      ('↑', '\x1b[A', null),
      ('↓', '\x1b[B', null),
      ('←', '\x1b[D', null),
      ('→', '\x1b[C', null),
    ];
    return Material(
      color: scheme.surfaceContainer,
      // Chips must not take focus: stealing it from the terminal closes the
      // soft keyboard, and Ctrl is latched precisely to combine with a key
      // typed on that keyboard.
      child: ExcludeFocus(
        child: SafeArea(
          top: false,
          bottom: bottomSafeArea,
          child: Row(
            children: [
              // Flexible, not intrinsic: the chips scroll within whatever the
              // assistant button leaves, instead of running underneath it.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      for (final (label, seq, custom) in keys) ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            selected: label == 'Ctrl' && ctrlLatched,
                            label: Text(
                              label == 'Ctrl' && ctrlLatched
                                  ? 'Ctrl（下一键）'
                                  : label,
                            ),
                            onSelected: (_) {
                              if (custom != null) {
                                custom();
                              } else {
                                onSend(seq);
                              }
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (onOpenAi != null) ...[
                SizedBox(
                  height: 24,
                  child: VerticalDivider(
                    width: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.8),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: Tooltip(
                    message: 'AI 助手',
                    child: FilledButton.tonalIcon(
                      onPressed: onOpenAi,
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('AI'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 34),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DisconnectedPane extends StatelessWidget {
  const _DisconnectedPane({
    required this.web,
    required this.status,
    required this.message,
    required this.profile,
    this.onConnect,
    this.onManage,
  });

  final bool web;
  final ResearchConnectionStatus status;
  final String message;
  final SshProfile? profile;
  final VoidCallback? onConnect;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: const Color(0xFF1A222D),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                web ? Icons.public_off : Icons.terminal_rounded,
                size: 48,
                color: scheme.primary.withValues(alpha: 0.85),
              ),
              const SizedBox(height: 16),
              Text(
                web
                    ? '浏览器无法建立原生 SSH 连接'
                    : status == ResearchConnectionStatus.connecting
                    ? '正在连接…'
                    : status == ResearchConnectionStatus.error
                    ? (message.isNotEmpty ? message : '连接失败')
                    : '尚未连接服务器',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: Colors.white70),
              ),
              if (profile != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${profile!.username}@${profile!.host}:${profile!.port}',
                  style: const TextStyle(color: Colors.white54),
                ),
              ],
              const SizedBox(height: 20),
              if (!web) ...[
                FilledButton.icon(
                  onPressed: status == ResearchConnectionStatus.connecting
                      ? null
                      : onConnect,
                  icon: const Icon(Icons.login),
                  label: Text(profile == null ? '添加并连接' : '连接'),
                ),
                const SizedBox(height: 8),
                TextButton(onPressed: onManage, child: const Text('连接管理')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionManagerSheet extends ConsumerStatefulWidget {
  const _ConnectionManagerSheet();

  @override
  ConsumerState<_ConnectionManagerSheet> createState() =>
      _ConnectionManagerSheetState();
}

class _ConnectionManagerSheetState
    extends ConsumerState<_ConnectionManagerSheet> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(researchTerminalProvider);
    final ctrl = ref.read(researchTerminalProvider.notifier);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => SafeArea(
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Row(
              children: [
                Text('连接管理', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                IconButton(
                  tooltip: '添加主机',
                  onPressed: () => _editProfile(null),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            if (state.profiles.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Text('还没有主机配置。点右上角 + 添加。'),
              ),
            for (final p in state.profiles)
              Card(
                child: ListTile(
                  leading: Icon(
                    p.authType == SshAuthType.privateKey
                        ? Icons.vpn_key_outlined
                        : Icons.password_outlined,
                  ),
                  title: Text(p.name),
                  subtitle: Text('${p.username}@${p.host}:${p.port}'),
                  selected: p.id == state.activeProfileId,
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      switch (v) {
                        case 'connect':
                          Navigator.of(context).pop();
                          await ctrl.connect(p);
                        case 'edit':
                          await _editProfile(p);
                        case 'delete':
                          await ctrl.deleteProfile(p.id);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'connect', child: Text('连接')),
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await ctrl.connect(p);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editProfile(SshProfile? existing) async {
    final result = await showDialog<_ProfileEditResult>(
      context: context,
      builder: (_) => _ProfileEditDialog(existing: existing),
    );
    if (result == null || !mounted) return;
    await ref
        .read(researchTerminalProvider.notifier)
        .saveProfile(
          result.profile,
          password: result.password,
          privateKeyPem: result.privateKeyPem,
          passphrase: result.passphrase,
        );
  }
}

class _ProfileEditResult {
  const _ProfileEditResult({
    required this.profile,
    this.password,
    this.privateKeyPem,
    this.passphrase,
  });
  final SshProfile profile;
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
}

class _ProfileEditDialog extends StatefulWidget {
  const _ProfileEditDialog({this.existing});
  final SshProfile? existing;

  @override
  State<_ProfileEditDialog> createState() => _ProfileEditDialogState();
}

class _ProfileEditDialogState extends State<_ProfileEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _password;
  late final TextEditingController _privateKey;
  late final TextEditingController _passphrase;
  late SshAuthType _auth;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 22}');
    _user = TextEditingController(text: e?.username ?? '');
    _password = TextEditingController();
    _privateKey = TextEditingController();
    _passphrase = TextEditingController();
    _auth = e?.authType ?? SshAuthType.password;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加主机' : '编辑主机'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '显示名称'),
              ),
              TextField(
                controller: _host,
                decoration: const InputDecoration(labelText: '主机'),
                autocorrect: false,
              ),
              TextField(
                controller: _port,
                decoration: const InputDecoration(labelText: '端口'),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: _user,
                decoration: const InputDecoration(labelText: '用户名'),
                autocorrect: false,
              ),
              const SizedBox(height: 8),
              SegmentedButton<SshAuthType>(
                segments: const [
                  ButtonSegment(value: SshAuthType.password, label: Text('密码')),
                  ButtonSegment(
                    value: SshAuthType.privateKey,
                    label: Text('私钥'),
                  ),
                ],
                selected: {_auth},
                onSelectionChanged: (s) => setState(() => _auth = s.first),
              ),
              const SizedBox(height: 8),
              if (_auth == SshAuthType.password)
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: widget.existing == null ? '密码' : '密码（留空保持原值）',
                  ),
                )
              else ...[
                TextField(
                  controller: _privateKey,
                  minLines: 3,
                  maxLines: 8,
                  decoration: InputDecoration(
                    labelText: widget.existing == null
                        ? 'OpenSSH 私钥 PEM'
                        : '私钥 PEM（留空保持原值）',
                    alignLabelWithHint: true,
                  ),
                ),
                TextField(
                  controller: _passphrase,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '私钥口令（可选）'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }

  void _submit() {
    final host = _host.text.trim();
    final user = _user.text.trim();
    if (host.isEmpty || user.isEmpty) return;
    final port = int.tryParse(_port.text.trim()) ?? 22;
    final id = widget.existing?.id ?? const Uuid().v4();
    final name = _name.text.trim().isEmpty ? host : _name.text.trim();
    final profile = SshProfile(
      id: id,
      name: name,
      host: host,
      port: port,
      username: user,
      authType: _auth,
      trustedHostKeyFingerprint: widget.existing?.trustedHostKeyFingerprint,
      lastUsedAt: widget.existing?.lastUsedAt,
    );
    Navigator.of(context).pop(
      _ProfileEditResult(
        profile: profile,
        password: _auth == SshAuthType.password
            ? (_password.text.isEmpty && widget.existing != null
                  ? null
                  : _password.text)
            : null,
        privateKeyPem: _auth == SshAuthType.privateKey
            ? (_privateKey.text.isEmpty && widget.existing != null
                  ? null
                  : _privateKey.text)
            : null,
        passphrase: _auth == SshAuthType.privateKey
            ? (_passphrase.text.isEmpty && widget.existing != null
                  ? null
                  : _passphrase.text)
            : null,
      ),
    );
  }
}

class _AiAssistPanel extends ConsumerStatefulWidget {
  const _AiAssistPanel({
    this.scrollController,
    this.embedded = false,
    this.onRequestAnalyze,
  });

  final ScrollController? scrollController;
  final bool embedded;
  final VoidCallback? onRequestAnalyze;

  @override
  ConsumerState<_AiAssistPanel> createState() => _AiAssistPanelState();
}

class _AiAssistPanelState extends ConsumerState<_AiAssistPanel> {
  final _editCtrl = TextEditingController();
  final _goalCtrl = TextEditingController();
  var _editing = false;

  @override
  void dispose() {
    _editCtrl.dispose();
    _goalCtrl.dispose();
    super.dispose();
  }

  Future<void> _runAnalyze({required bool preferGoal}) async {
    final ctrl = ref.read(researchTerminalProvider.notifier);
    final goal = _goalCtrl.text.trim();
    await ctrl.analyzeWithAi(userGoal: preferGoal || goal.isNotEmpty ? goal : null);
  }

  Future<void> _confirmExecute(CommandProposal proposal) async {
    final state = ref.read(researchTerminalProvider);
    final host = state.activeProfile;
    if (host == null) return;
    final command = _editing ? _editCtrl.text : proposal.command;
    final local = const CommandRiskClassifier().classify(command);
    final risk = CommandRisk.max(proposal.risk, local.risk);

    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('最终确认', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text('主机：${host.username}@${host.host}:${host.port}'),
            const Text('工作目录：当前 shell cwd（未探测）'),
            const SizedBox(height: 8),
            Text('风险：${risk.label}'),
            const SizedBox(height: 8),
            SelectableText(
              command,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            if (proposal.impacts.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('影响：${proposal.impacts.join('；')}'),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: risk == CommandRisk.blocked
                      ? null
                      : () => Navigator.of(ctx).pop(true),
                  child: const Text('确认执行'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;

    final approved = ref
        .read(researchTerminalProvider.notifier)
        .approveCurrentProposal(command: command, cwdHint: 'cwd');
    if (approved == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('审批已失效或命令不可执行')));
      return;
    }
    try {
      ref.read(researchTerminalProvider.notifier).executeApproved(approved);
      setState(() {
        _editing = false;
      });
      if (mounted && !widget.embedded) {
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(researchTerminalProvider);
    final ctrl = ref.read(researchTerminalProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final proposal = state.proposal;
    final preview = ctrl.previewForAi();

    return Material(
      color: scheme.surfaceContainerLow,
      child: ListView(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, color: scheme.primary),
              const SizedBox(width: 8),
              Text('AI 助手', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (widget.embedded)
                IconButton(
                  tooltip: '生成命令',
                  onPressed: state.analyzing
                      ? null
                      : () => unawaited(_runAnalyze(preferGoal: true)),
                  icon: state.analyzing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('你想做什么', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(
            controller: _goalCtrl,
            minLines: 2,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) {
              if (!state.analyzing) unawaited(_runAnalyze(preferGoal: true));
            },
            decoration: const InputDecoration(
              hintText: '例如：查看 GPU 占用、定位 OOM、重启某个 tmux 里的训练…',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: state.analyzing
                    ? null
                    : () => unawaited(_runAnalyze(preferGoal: true)),
                icon: state.analyzing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(state.analyzing ? '思考中…' : '按需求生成命令'),
              ),
              OutlinedButton.icon(
                onPressed: state.analyzing
                    ? null
                    : () => unawaited(_runAnalyze(preferGoal: false)),
                icon: const Icon(Icons.terminal, size: 18),
                label: const Text('只分析终端输出'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('上下文行数', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 20, label: Text('20')),
              ButtonSegment(value: 36, label: Text('36')),
              ButtonSegment(value: 50, label: Text('50')),
              ButtonSegment(value: 100, label: Text('100')),
            ],
            selected: {state.aiContextLines},
            onSelectionChanged: (s) =>
                unawaited(ctrl.setAiContextLines(s.first)),
          ),
          const SizedBox(height: 12),
          Text(
            '附带终端预览（已脱敏，可选）',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 120),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                preview.isEmpty ? '（终端尚无输出；仅按需求生成时可不需要）' : preview,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          if (proposal != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('理解 / 诊断', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(proposal.diagnosis),
                    if (proposal.evidence.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final e in proposal.evidence)
                            Chip(
                              label: Text(
                                e,
                                style: const TextStyle(fontSize: 11),
                              ),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (proposal.canOfferExecute) ...[
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '命令建议',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const Spacer(),
                          _RiskBadge(risk: proposal.risk),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_editing)
                        TextField(
                          controller: _editCtrl,
                          minLines: 2,
                          maxLines: 5,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '编辑命令',
                          ),
                          onChanged: (v) => ctrl.editProposalCommand(v),
                        )
                      else
                        SelectableText(
                          proposal.command,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                      if (proposal.impacts.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '影响：${proposal.impacts.join('；')}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (proposal.nonImpacts.isNotEmpty) ...[
                        Text(
                          '不会：${proposal.nonImpacts.join('；')}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: () {
                              ctrl.clearProposal();
                              setState(() => _editing = false);
                            },
                            child: const Text('拒绝'),
                          ),
                          OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _editing = !_editing;
                                if (_editing) {
                                  _editCtrl.text = proposal.command;
                                }
                              });
                            },
                            child: Text(_editing ? '完成编辑' : '编辑'),
                          ),
                          FilledButton(
                            onPressed: () => _confirmExecute(proposal),
                            child: const Text('确认执行'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ] else if (!proposal.parseOk) ...[
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '模型返回未能解析为可执行建议',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        proposal.rawModelText ?? proposal.diagnosis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ] else if (widget.embedded) ...[
            const SizedBox(height: 24),
            Text(
              '写下你想做什么，或分析终端输出。AI 只给建议，确认后才会写入终端。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          // Keep ResearchPrefs default visible for tests / docs.
          if (state.aiContextLines == ResearchPrefs.defaultAiContextLines)
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

class _RiskBadge extends StatelessWidget {
  const _RiskBadge({required this.risk});
  final CommandRisk risk;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (risk) {
      CommandRisk.low => const Color(0xFF2E7D4F),
      CommandRisk.medium => scheme.tertiary,
      CommandRisk.high => scheme.error,
      CommandRisk.blocked => scheme.error,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        '风险 ${risk.label}',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
