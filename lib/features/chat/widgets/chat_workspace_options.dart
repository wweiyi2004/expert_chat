import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../../core/application_surface.dart';
import '../../../core/prototype_widgets.dart';
import 'composer_popover.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/desktop_providers.dart';
import '../../../domain/desktop/workspace_host.dart';
import '../../../state/conversation_workspace_bindings.dart';
import '../../workspaces/desktop_workspaces_page.dart';
import '../../research/research_terminal_page.dart';
import '../../remote/remote_tasks_page.dart';
import '../../remote/device_agent_page.dart';
import '../../../state/session_policy.dart';
import '../../../state/research_terminal_controller.dart';

String _displayPath(String path) {
  if (path.startsWith(r'\\?\UNC\')) return r'\\' + path.substring(8);
  return path.startsWith(r'\\?\') ? path.substring(4) : path;
}

Future<void> showChatWorkspaceOptions(
  BuildContext context,
  String conversationId,
) => showComposerPopover<void>(
  context,
  width: 440,
  builder: (_) => _WorkspacePicker(conversationId: conversationId),
);

class ChatWorkspaceBar extends ConsumerWidget {
  const ChatWorkspaceBar({
    super.key,
    required this.conversationId,
    required this.busy,
    this.plain = false,
  });
  final String conversationId;
  final bool busy;
  final bool plain;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy =
        ref.watch(sessionPolicyProvider)[conversationId] ??
        const SessionPolicy();
    if (policy.sshProfileId.isNotEmpty) {
      final profiles = ref.watch(researchTerminalProvider).profiles;
      final name =
          profiles
              .where((p) => p.id == policy.sshProfileId)
              .firstOrNull
              ?.name ??
          '不可用';
      return _WorkspaceLocation(
        plain: plain,
        label: 'SSH · $name : ${policy.remoteRoot}',
        icon: Icons.dns_outlined,
        onTap: () => showChatWorkspaceOptions(context, conversationId),
      );
    }
    final selected = ref.watch(
      conversationWorkspaceBindingsProvider.select(
        (value) => value[conversationId],
      ),
    );
    if (!ref.watch(desktopWorkspaceHostProvider).supported) {
      return _WorkspaceLocation(
        plain: plain,
        label: defaultTargetPlatform == TargetPlatform.android
            ? '本机 · Android'
            : '当前设备',
        tooltip: '在当前设备执行；也可选择 SSH 或连接远程电脑',
        icon: defaultTargetPlatform == TargetPlatform.android
            ? Icons.phone_android
            : Icons.devices,
        onTap: () => showChatWorkspaceOptions(context, conversationId),
      );
    }
    final workspaces = ref.watch(desktopWorkspacesProvider);
    final workspace = workspaces.value
        ?.where((w) => w.id == (selected ?? defaultDesktopWorkspaceId))
        .firstOrNull;
    final path = workspaces.hasError
        ? '工作目录暂不可用'
        : workspace == null
        ? (workspaces.isLoading ? '正在准备工作目录…' : '所选工作区不可用')
        : _displayPath(workspace.root);
    return _WorkspaceLocation(
      plain: plain,
      label: '本机 · ${workspace?.name ?? '默认工作区'}',
      tooltip: workspaces.hasError ? '${workspaces.error}' : path,
      icon: Icons.folder_open_outlined,
      onTap: () => showChatWorkspaceOptions(context, conversationId),
    );
  }
}

class _WorkspacePicker extends ConsumerStatefulWidget {
  const _WorkspacePicker({required this.conversationId});
  final String conversationId;
  @override
  ConsumerState<_WorkspacePicker> createState() => _WorkspacePickerState();
}

class _WorkspacePickerState extends ConsumerState<_WorkspacePicker> {
  bool _saving = false;
  String? _error;
  String _query = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(desktopWorkspacesProvider);
    });
  }

  Future<void> _select(String? id) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final bindings = ref.read(conversationWorkspaceBindingsProvider.notifier);
      final previous = ref.read(
        conversationWorkspaceBindingsProvider,
      )[widget.conversationId];
      await bindings.select(widget.conversationId, id);
      if (!mounted) return;
      final latest =
          ref.read(sessionPolicyProvider)[widget.conversationId] ??
          const SessionPolicy();
      if (latest.sshProfileId.isNotEmpty) {
        try {
          await ref
              .read(sessionPolicyProvider.notifier)
              .save(widget.conversationId, latest.copyWith(sshProfileId: ''));
        } catch (_) {
          try {
            await bindings.selectIfCurrent(widget.conversationId, id, previous);
          } catch (_) {
            /* SSH remains the active location. */
          }
          rethrow;
        }
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(
      conversationWorkspaceBindingsProvider,
    )[widget.conversationId];
    final spaces = ref.watch(desktopWorkspacesProvider);
    final policy =
        ref.watch(sessionPolicyProvider)[widget.conversationId] ??
        const SessionPolicy();
    final research = ref.watch(researchTerminalProvider);
    final localWorkspaces = ref.watch(desktopWorkspaceHostProvider).supported;
    return PopScope(
      canPop: !_saving,
      child: ComposerPopoverFrame(
        title: '执行位置',
        body: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          children: [
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索项目或目录',
              ),
              onChanged: (value) =>
                  setState(() => _query = value.toLowerCase()),
            ),
            const SizedBox(height: 8),

            Text(
              localWorkspaces
                  ? '未选本机项目时使用默认工作区。目录规则继续约束文件工具；含只读或拒绝规则的工作区不开放任意命令。'
                  : '在当前设备处理任务。需要电脑文件或命令时，选择 SSH 或连接远程电脑。',
            ),
            const SizedBox(height: 12),
            if (_saving || spaces.isLoading) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (spaces.hasError)
              Text(
                '${spaces.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ListTile(
              key: const ValueKey('use-default-workspace'),
              leading: Icon(
                current == null && policy.sshProfileId.isEmpty
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(localWorkspaces ? '默认工作区' : '当前设备'),
              subtitle: Text(
                localWorkspaces ? '不绑定项目，使用应用专用目录' : '使用本机模型连接和已开启的设备能力',
              ),
              onTap: _saving ? null : () => _select(null),
            ),
            for (final workspace in spaces.value ?? <DesktopWorkspace>[])
              if (workspace.id != defaultDesktopWorkspaceId &&
                  ('${workspace.name} ${workspace.root}')
                      .toLowerCase()
                      .contains(_query))
                ListTile(
                  key: ValueKey('select-workspace-${workspace.id}'),
                  leading: Icon(
                    current == workspace.id && policy.sshProfileId.isEmpty
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(workspace.name),
                  subtitle: Text(
                    '${_displayPath(workspace.root)}\n本机 · ${workspace.scopes.map((s) => '${s.name}：${s.access.label}').join('、')}',
                  ),
                  onTap: _saving ? null : () => _select(workspace.id),
                ),
            const SizedBox(height: 12),
            const Text('SSH 主机'),
            for (final profile in research.profiles)
              if (profile.name.toLowerCase().contains(_query))
                ListTile(
                  key: ValueKey('select-ssh-${profile.id}'),
                  leading: Icon(
                    policy.sshProfileId == profile.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text('SSH · ${profile.name}'),
                  subtitle: Text('会话目录 ${policy.remoteRoot} · 使用SSH账号读写权限'),
                  onTap: _saving
                      ? null
                      : () async {
                          setState(() => _saving = true);
                          try {
                            await ref
                                .read(sessionPolicyProvider.notifier)
                                .save(
                                  widget.conversationId,
                                  policy.copyWith(sshProfileId: profile.id),
                                );
                            if (context.mounted) {
                              Navigator.pop(context);
                            }
                          } catch (error) {
                            if (mounted) {
                              setState(() {
                                _saving = false;
                                _error = '$error';
                              });
                            }
                          }
                        },
                ),
            if (policy.sshProfileId.isNotEmpty)
              TextFormField(
                initialValue: policy.remoteRoot,
                decoration: const InputDecoration(
                  labelText: 'SSH 工作目录',
                  helperText: '绝对路径或 .，按回车保存',
                ),
                onFieldSubmitted: (value) async {
                  try {
                    await ref
                        .read(sessionPolicyProvider.notifier)
                        .save(
                          widget.conversationId,
                          policy.copyWith(
                            remoteRoot: value.trim().isEmpty
                                ? '.'
                                : value.trim(),
                          ),
                        );
                  } catch (error) {
                    if (mounted) setState(() => _error = '$error');
                  }
                },
              ),
            const SizedBox(height: 12),
            const Text('添加执行位置'),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('添加 / 管理 SSH 主机'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ResearchTerminalPage(),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.computer_outlined),
              title: const Text('远程电脑'),
              subtitle: const Text('在专用页面中使用 · 配对、任务、审批与成果'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const RemoteTasksPage(),
                ),
              ),
            ),
            if (defaultTargetPlatform == TargetPlatform.android)
              ListTile(
                leading: const Icon(Icons.phone_android),
                title: const Text('Android 本机控制'),
                subtitle: const Text('在专用页面中使用 · 系统授权与本次控制'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DeviceAgentPage(),
                  ),
                ),
              ),
            if (localWorkspaces)
              ListTile(
                leading: const Icon(Icons.folder_copy_outlined),
                title: const Text('管理工作区和权限'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _saving
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          applicationSurfaceRoute<void>(
                            context,
                            (_) => const DesktopWorkspacesPage(),
                            title: '管理执行位置',
                          ),
                        );
                        if (mounted) ref.invalidate(desktopWorkspacesProvider);
                      },
              ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceLocation extends StatelessWidget {
  const _WorkspaceLocation({
    required this.label,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.plain = false,
  });
  final bool plain;
  final String label;
  final String? tooltip;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: const ValueKey('chat-workspace-bar'),
    child: plain
        ? Tooltip(
            message: tooltip ?? label,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: PrototypeColors.of(context).muted,
                        ),
                      ),
                    ),
                    const Icon(Icons.expand_more, size: 14),
                  ],
                ),
              ),
            ),
          )
        : PrototypeChip(
            label: label,
            tooltip: tooltip ?? label,
            icon: icon,
            tone: PrototypeTone.accent,
            onPressed: onTap,
          ),
  );
}
