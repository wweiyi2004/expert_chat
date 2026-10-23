import 'package:flutter/material.dart';
import 'composer_popover.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/desktop_providers.dart';
import '../../../domain/desktop/workspace_host.dart';
import '../../../state/conversation_workspace_bindings.dart';
import '../../workspaces/desktop_workspaces_page.dart';
import 'session_policy_controls.dart';
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
  });
  final String conversationId;
  final bool busy;
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
      label: path,
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
      await ref
          .read(conversationWorkspaceBindingsProvider.notifier)
          .select(widget.conversationId, id);
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
    return PopScope(
      canPop: !_saving,
      child: ComposerPopoverFrame(
        title: '项目与执行位置',
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
            SessionPolicyControls(
              conversationId: widget.conversationId,
              workMode: true,
            ),
            const Text('未选本机项目时使用默认工作区。目录规则继续约束文件工具；含只读或拒绝规则的工作区不开放任意命令。'),
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
                current == null
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: const Text('默认工作区'),
              subtitle: const Text('不绑定项目，使用应用专用目录'),
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
                    current == workspace.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(workspace.name),
                  subtitle: Text(_displayPath(workspace.root)),
                  onTap: _saving ? null : () => _select(workspace.id),
                ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.folder_copy_outlined),
              title: const Text('管理工作区和权限'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _saving
                  ? null
                  : () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const DesktopWorkspacesPage(),
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
  });
  final String label;
  final String? tooltip;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip ?? label,
    child: InkWell(
      key: const ValueKey('chat-workspace-bar'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: Row(
          children: [
            Icon(icon, size: 15, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontSize: 11),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.expand_more,
              size: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    ),
  );
}
