import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/desktop_providers.dart';
import '../../core/prototype_widgets.dart';
import '../../state/settings_controller.dart';
import '../../state/research_mode_fx.dart';
import '../../state/research_terminal_controller.dart';
import '../shared/recovery_notice.dart';
import '../workspaces/desktop_workspaces_page.dart';
import '../remote/remote_tasks_page.dart';
import '../remote/device_agent_page.dart';
import 'shell_tab.dart';

class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({
    super.key,
    this.onOpenNavigation,
    this.embedded = false,
    this.showConnections = true,
    this.showModules = true,
  });
  final bool embedded, showConnections, showModules;
  final VoidCallback? onOpenNavigation;
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
    final page = Scaffold(
      appBar: AppBar(
        title: const Text('工具'),
        automaticallyImplyLeading: false,
        leading: widget.onOpenNavigation == null
            ? null
            : IconButton(
                tooltip: '打开侧边栏',
                onPressed: widget.onOpenNavigation,
                icon: const Icon(Icons.menu_rounded),
              ),
      ),
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
            child: _ToolsBodyList(
              embedded: widget.embedded,
              children: [
                if (widget.showConnections)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.devices),
                      title: const Text('远程电脑任务'),
                      subtitle: const Text('配对电脑、离线执行、事件续传与逐步审批'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const RemoteTasksPage(),
                        ),
                      ),
                    ),
                  ),
                if (widget.showConnections &&
                    !kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.android)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.touch_app),
                      title: const Text('Android 本机控制'),
                      subtitle: const Text('系统授权、观察、动作、截图与停止'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const DeviceAgentPage(),
                        ),
                      ),
                    ),
                  ),
                if (widget.showConnections &&
                    ref.watch(desktopWorkspaceHostProvider).supported) ...[
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.folder_copy_outlined),
                      title: const Text('电脑工作区'),
                      subtitle: const Text('添加项目目录，管理只读、读写与拒绝访问范围'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const DesktopWorkspacesPage(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (widget.showConnections && s.researchModeEnabled)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.terminal),
                      title: const Text('SSH 主机与科研终端'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openShellTab(ref, ShellTab.terminal),
                    ),
                  ),
                if (_error != null)
                  RecoveryNotice(error: _error!, title: '功能设置未完成'),
                if (widget.showModules)
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
                        const SizedBox(height: 12),
                        _CreationModeCard(
                          enabled: s.creationModeEnabled,
                          onChanged: (enabled) =>
                              _change(() => _setCreationModeEnabled(enabled)),
                          onOpenStudio: s.creationModeEnabled
                              ? () => openShellTab(ref, ShellTab.studio)
                              : null,
                        ),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 8),
                          child: Text(
                            '实验功能',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
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
    return widget.embedded ? page.body! : page;
  }
}

/// One optional feature: icon, name and switch; an entry row appears once on.
/// Turning a feature off only hides it; its data stays on the device.
class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.toggle,
    required this.openLabel,
    this.onOpen,
    this.badge,
    this.note,
  });

  final IconData icon;
  final String title;
  final Widget toggle;
  final String openLabel;
  final VoidCallback? onOpen;
  final String? badge;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    return Container(
      key: ValueKey('feature-module-$title'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: c.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: c.ink,
                  ),
                ),
              ),
              if (badge != null)
                Text(badge!, style: TextStyle(fontSize: 11, color: c.muted)),
              const SizedBox(width: 8),
              toggle,
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(left: 24, bottom: 4),
              child: Text(
                note!,
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
            ),
          if (onOpen != null)
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Align(
                alignment: Alignment.centerLeft,
                child: PrototypeButton(
                  label: openLabel,
                  small: true,
                  variant: PrototypeButtonVariant.ghost,
                  onPressed: onOpen,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

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
  Widget build(BuildContext context) => _FeatureCard(
    icon: Icons.school_outlined,
    title: '学习模式',
    toggle: PrototypeSwitch(
      value: enabled,
      onChanged: onChanged,
      semanticLabel: '功能模块开关',
    ),
    openLabel: '进入学习中心',
    onOpen: enabled ? onOpenStudy : null,
  );
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
  Widget build(BuildContext context) => _FeatureCard(
    icon: Icons.menu_book_outlined,
    title: '创作模式',
    toggle: PrototypeSwitch(
      value: enabled,
      onChanged: onChanged,
      semanticLabel: '功能模块开关',
    ),
    openLabel: '进入创作中心',
    onOpen: enabled ? onOpenStudio : null,
  );
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
    const webBlocked = kIsWeb;
    return _FeatureCard(
      icon: Icons.terminal_rounded,
      title: '科研模式',
      badge: '实验性',
      note: webBlocked ? '浏览器不支持 SSH' : null,
      toggle: KeyedSubtree(
        key: _switchKey,
        child: PrototypeSwitch(
          value: widget.enabled && !webBlocked,
          onChanged: webBlocked
              ? null
              : (v) => widget.onChanged(v, _switchCenterGlobal()),
        ),
      ),
      openLabel: '进入科研终端',
      onOpen: widget.enabled && !webBlocked ? widget.onOpenTerminal : null,
    );
  }
}

class _ToolsBodyList extends StatelessWidget {
  const _ToolsBodyList({required this.embedded, required this.children});
  final bool embedded;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final c = PrototypeColors.of(context);
    final content = embedded
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          )
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: children,
          );
    return Theme(
      data: base.copyWith(
        cardTheme: const CardThemeData(
          color: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
        listTileTheme: ListTileThemeData(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 0,
            vertical: 2,
          ),
          dense: true,
          minTileHeight: 44,
          minLeadingWidth: 16,
          horizontalTitleGap: 8,
          iconColor: c.muted,
          titleTextStyle: TextStyle(fontSize: 13, color: c.ink),
          subtitleTextStyle: TextStyle(fontSize: 12, color: c.muted),
        ),
      ),
      child: content,
    );
  }
}
