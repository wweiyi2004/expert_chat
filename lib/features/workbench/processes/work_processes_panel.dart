import '../../../core/runtime_listenable.dart';
import 'package:expert_chat/core/app_toast.dart';
import '../workbench_split_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/work_processes.dart';

class WorkProcessesPanel extends ConsumerStatefulWidget {
  const WorkProcessesPanel({
    super.key,
    required this.conversationId,
    this.initialTab = 0,
  });
  final int initialTab;
  final String conversationId;
  @override
  ConsumerState<WorkProcessesPanel> createState() => _WorkProcessesPanelState();
}

class _WorkProcessesPanelState extends ConsumerState<WorkProcessesPanel> {
  String? _selected;
  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(workProcessesProvider),
        hooks = ref.watch(workHooksProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([
        runtimeListenable(runtime),
        runtimeListenable(hooks),
      ]),
      builder: (context, _) {
        return DefaultTabController(
          initialIndex: widget.initialTab.clamp(0, 2),
          length: 3,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: '命令 / 构建'),
                  Tab(text: '常驻服务'),
                  Tab(text: '文件 Hooks'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _processes(runtime, false),
                    _processes(runtime, true),
                    _hooks(hooks),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _processes(WorkProcessRuntime runtime, bool service) {
    final records = runtime.records
        .where(
          (r) =>
              r.conversationId == widget.conversationId && r.service == service,
        )
        .toList()
        .reversed
        .toList();
    if (records.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                service ? Icons.dns_outlined : Icons.terminal,
                size: 36,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(service ? '后台服务' : '后台命令与构建'),
              const SizedBox(height: 8),
              Text(
                service
                    ? '让会话启动开发服务器等常驻命令，可在这里查看日志、停止和重启。'
                    : '让会话在后台运行测试或构建，进程完成后自动通知原任务。',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final selected =
        records.where((r) => r.id == _selected).firstOrNull ?? records.first;
    final list = ListView.builder(
      itemCount: records.length,
      itemBuilder: (context, i) {
        final r = records[i];
        return ListTile(
          dense: true,
          selected: r.id == selected.id,
          leading: Icon(
            r.active
                ? Icons.play_circle_outline
                : r.status == WorkProcessStatus.completed
                ? Icons.check_circle_outline
                : Icons.stop_circle_outlined,
            size: 19,
            color: r.active ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(r.command, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${_status(r.status)}${r.exitCode == null ? '' : ' · exit ${r.exitCode}'}',
          ),
          onTap: () => setState(() => _selected = r.id),
        );
      },
    );
    final detail = _detail(runtime, selected);
    return LayoutBuilder(
      builder: (context, size) {
        return WorkbenchSplitView(first: list, second: detail);
      },
    );
  }

  Widget _detail(WorkProcessRuntime runtime, WorkProcessRecord r) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_status(r.status)}${r.exitCode == null ? '' : ' · exit ${r.exitCode}'}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (r.active)
                IconButton(
                  tooltip: '停止进程',
                  onPressed: () => runtime.stop(r.id),
                  icon: const Icon(Icons.stop_circle_outlined, size: 20),
                )
              else if (!r.restored)
                IconButton(
                  tooltip: '重启原命令',
                  onPressed: () {
                    try {
                      final id = runtime.restart(r.id);
                      setState(() => _selected = id);
                    } catch (error) {
                      _error(error);
                    }
                  },
                  icon: const Icon(Icons.restart_alt, size: 20),
                ),
            ],
          ),
        ),
        Expanded(
          child: SelectionArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              children: [
                Text(
                  r.command,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 6),
                Text(r.target, style: theme.textTheme.bodySmall),
                Text(r.id, style: theme.textTheme.bodySmall),
                if (r.ownerAgentId != null)
                  Text(
                    '所属代理：${r.ownerAgentId}',
                    style: theme.textTheme.bodySmall,
                  ),
                if (r.error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      r.error,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (r.outputs.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('产物：${r.outputs.join(', ')}'),
                ],
                const SizedBox(height: 12),
                Text(
                  r.logsTruncated ? '日志（保留最后 64,000 字符）' : '日志',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    r.log.isEmpty ? '等待进程输出…' : r.log,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _hooks(WorkHookRuntime runtime) {
    final records = runtime.records
        .where((r) => r.definition.conversationId == widget.conversationId)
        .toList();
    final root = runtime.boundRoot(widget.conversationId);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '文件变化自动执行',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: root == null
                        ? null
                        : () => _addHook(runtime, root),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加 Hook'),
                  ),
                ],
              ),
              Text(
                root == null
                    ? '先在会话中使用本机工作区。Hook 仅在绑定的原工作区可用，SSH 文件监控尚未开放。'
                    : '当前目录：$root',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(
                '仅运行你配置的固定命令，沿用会话批准策略；默认防抖 800ms，执行期间不重叠触发，忽略常见构建目录与自身输出。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: records.isEmpty
              ? const Center(child: Text('尚未配置文件 Hook'))
              : ListView(
                  children: records
                      .map(
                        (r) => ListTile(
                          isThreeLine: true,
                          leading: Switch(
                            value: r.definition.enabled,
                            onChanged: (v) async {
                              try {
                                await runtime.save(
                                  r.definition.copyWith(enabled: v),
                                );
                              } catch (error) {
                                _error(error);
                              }
                            },
                          ),
                          title: Text(
                            r.definition.command,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${r.definition.watchPath.isEmpty ? '整个工作区' : r.definition.watchPath} · ${r.status}${r.error.isEmpty ? '' : '\n${r.error}'}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: '删除 Hook',
                            onPressed: () async {
                              try {
                                await runtime.remove(r.definition.id);
                              } catch (error) {
                                _error(error);
                              }
                            },
                            icon: const Icon(Icons.delete_outline, size: 20),
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }

  Future<void> _addHook(WorkHookRuntime runtime, String root) async {
    final command = TextEditingController(), path = TextEditingController();
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('配置文件 Hook'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(root, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                TextField(
                  controller: path,
                  decoration: const InputDecoration(
                    labelText: '监控相对路径（可留空）',
                    hintText: 'lib 或 src',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: command,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '固定执行命令',
                    hintText: 'flutter test',
                  ),
                ),
                const SizedBox(height: 8),
                const Text('文件变化只触发此命令；文件路径不会拼接到 Shell。运行仍需通过会话权限检查。'),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await runtime.save(
                    WorkHookDefinition(
                      id: 'hook_${DateTime.now().microsecondsSinceEpoch}',
                      conversationId: widget.conversationId,
                      root: root,
                      command: command.text.trim(),
                      watchPath: path.text.trim(),
                    ),
                  );
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                } catch (e) {
                  update(() => error = '$e');
                }
              },
              child: const Text('保存并启用'),
            ),
          ],
        ),
      ),
    );
    command.dispose();
    path.dispose();
    if (saved == true && mounted) {
      AppToastMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Hook 已保存并启用')));
    }
  }

  void _error(Object error) {
    if (mounted) {
      AppToastMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

String _status(WorkProcessStatus s) => switch (s) {
  WorkProcessStatus.starting => '启动中',
  WorkProcessStatus.running => '运行中',
  WorkProcessStatus.stopping => '停止中',
  WorkProcessStatus.completed => '完成',
  WorkProcessStatus.failed => '失败',
  WorkProcessStatus.cancelled => '已取消',
  WorkProcessStatus.interrupted => '已中断',
};
