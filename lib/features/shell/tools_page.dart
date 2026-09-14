import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/settings_controller.dart';
import '../../state/research_mode_fx.dart';
import '../../state/research_terminal_controller.dart';
import '../shared/recovery_notice.dart';
import 'shell_tab.dart';

class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({super.key});
  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  bool _changing = false;
  Object? _error;

  Future<void> _change(Future<void> Function() action) async {
    if (_changing) return;
    setState(() {
      _changing = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _setStudyModeEnabled(bool enabled) async {
    final controller = ref.read(settingsControllerProvider.notifier);
    if (enabled) {
      await controller.setStudyModeEnabled(true);
      return;
    }
    if (ref.read(shellTabProvider) == ShellTab.study) {
      ref.read(shellTabProvider.notifier).set(ShellTab.tools);
    }
    await controller.setStudyModeEnabled(false);
  }

  Future<void> _setCreationModeEnabled(bool enabled) async {
    final controller = ref.read(settingsControllerProvider.notifier);
    if (enabled) {
      await controller.setCreationModeEnabled(true);
      return;
    }
    if (ref.read(shellTabProvider) == ShellTab.studio) {
      ref.read(shellTabProvider.notifier).set(ShellTab.tools);
    }
    await controller.setCreationModeEnabled(false);
  }

  Future<void> _setResearchModeEnabled(
    bool enabled, {
    Offset? originGlobal,
  }) async {
    final controller = ref.read(settingsControllerProvider.notifier);
    if (enabled) {
      await controller.setResearchModeEnabled(true);
      // Rainbow ripple expands from the research switch itself.
      ref
          .read(researchModeFxProvider.notifier)
          .play(originGlobal: originGlobal);
      return;
    }

    final research = ref.read(researchTerminalProvider);
    final hasSession =
        research.isConnected ||
        research.status == ResearchConnectionStatus.connecting;
    if (hasSession) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.link_off_outlined),
          title: const Text('关闭科研模式？'),
          content: const Text(
            '将断开当前 SSH 连接；远端 tmux 中的任务仍会继续运行。'
            '科研终端将停用，可在工具页重新开启。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('断开并关闭'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    if (ref.read(shellTabProvider) == ShellTab.terminal) {
      ref.read(shellTabProvider.notifier).set(ShellTab.tools);
    }
    await ref.read(researchTerminalProvider.notifier).releaseAll();
    await controller.setResearchModeEnabled(false);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('工具'), automaticallyImplyLeading: false),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Padding(
          padding: const EdgeInsets.all(20),
          child: RecoveryNotice(
            error: error,
            title: '工具设置暂时无法加载',
            onRetry: () async {
              ref.invalidate(settingsControllerProvider);
              await ref.read(settingsControllerProvider.future);
            },
          ),
        ),
        data: (s) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                const Text('按需开启学习、创作与科研功能，已有内容会保留。'),
                const SizedBox(height: 16),
                if (_error != null)
                  RecoveryNotice(error: _error!, title: '功能设置未完成'),
                AbsorbPointer(
                  absorbing: _changing,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StudyModeCard(
                        enabled: s.studyModeEnabled,
                        onChanged: (enabled) =>
                            _change(() => _setStudyModeEnabled(enabled)),
                        onOpenStudy: s.studyModeEnabled
                            ? () => openShellTab(ref, ShellTab.study)
                            : null,
                      ),
                      const SizedBox(height: 24),
                      _CreationModeCard(
                        enabled: s.creationModeEnabled,
                        onChanged: (enabled) =>
                            _change(() => _setCreationModeEnabled(enabled)),
                        onOpenStudio: s.creationModeEnabled
                            ? () => openShellTab(ref, ShellTab.studio)
                            : null,
                      ),
                      const SizedBox(height: 24),
                      const Text('实验功能'),
                      const SizedBox(height: 8),
                      _ResearchModeCard(
                        enabled: s.researchModeEnabled,
                        onChanged: (enabled, origin) => _change(
                          () => _setResearchModeEnabled(
                            enabled,
                            originGlobal: origin,
                          ),
                        ),
                        onOpenTerminal: s.researchModeEnabled
                            ? () => openShellTab(ref, ShellTab.terminal)
                            : null,
                      ),
                    ],
                  ),
                ),
                if (_changing)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Optional workspace cards retain each feature's existing enablement state.
class _StudyModeCard extends StatelessWidget {
  const _StudyModeCard({
    required this.enabled,
    required this.onChanged,
    this.onOpenStudy,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onOpenStudy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.school_rounded,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '学习模式',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '导师、课程、刷题与间隔复习。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(value: enabled, onChanged: onChanged),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '关闭后隐藏学习入口；课程、卡片与错题本仍保留在本机。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (enabled && onOpenStudy != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onOpenStudy,
              icon: const Icon(Icons.school_outlined, size: 18),
              label: const Text('进入学习中心'),
            ),
          ),
        ],
      ],
    );
  }
}

class _CreationModeCard extends StatelessWidget {
  const _CreationModeCard({
    required this.enabled,
    required this.onChanged,
    this.onOpenStudio,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onOpenStudio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.menu_book_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '创作模式',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '导演故事、角色库与世界书。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(value: enabled, onChanged: onChanged),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '关闭后停用创作中心；角色与草稿仍保留。聊天里仍可直接开导演故事。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (enabled && onOpenStudio != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onOpenStudio,
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              label: const Text('进入创作中心'),
            ),
          ),
        ],
      ],
    );
  }
}

/// Experimental SSH workspace.
class _ResearchModeCard extends StatefulWidget {
  const _ResearchModeCard({
    required this.enabled,
    required this.onChanged,
    this.onOpenTerminal,
  });

  final bool enabled;

  /// [originGlobal] is the switch center in global coordinates (ripple source).
  final void Function(bool enabled, Offset? originGlobal) onChanged;
  final VoidCallback? onOpenTerminal;

  @override
  State<_ResearchModeCard> createState() => _ResearchModeCardState();
}

class _ResearchModeCardState extends State<_ResearchModeCard> {
  final _switchKey = GlobalKey();

  Offset? _switchCenterGlobal() {
    final box = _switchKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final webBlocked = kIsWeb;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.terminal_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '科研模式',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '实验性',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: scheme.onSecondaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        webBlocked
                            ? '浏览器无法直接建立原生 SSH 连接。'
                            : '启用 SSH 终端、tmux 会话和 AI 命令审批。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                KeyedSubtree(
                  key: _switchKey,
                  child: Switch.adaptive(
                    value: widget.enabled && !webBlocked,
                    onChanged: webBlocked
                        ? null
                        : (v) => widget.onChanged(v, _switchCenterGlobal()),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '关闭时，终端入口不会显示，服务器配置也不会进入普通 AI 会话。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (widget.enabled && !webBlocked && widget.onOpenTerminal != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: widget.onOpenTerminal,
              icon: const Icon(Icons.terminal_rounded, size: 18),
              label: const Text('进入科研终端'),
            ),
          ),
        ],
      ],
    );
  }
}
