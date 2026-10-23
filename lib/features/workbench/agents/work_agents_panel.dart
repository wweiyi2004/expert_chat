import 'agent_cluster_card.dart';
import '../workbench_split_view.dart';
import 'work_agent_model_pool.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/work_agents.dart';

class WorkAgentsPanel extends ConsumerStatefulWidget {
  const WorkAgentsPanel({super.key, required this.conversationId});
  final String conversationId;
  @override
  ConsumerState<WorkAgentsPanel> createState() => _WorkAgentsPanelState();
}

class _WorkAgentsPanelState extends ConsumerState<WorkAgentsPanel> {
  String? _selected;
  final Set<String> _collapsed = {};
  final _message = TextEditingController();
  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(workAgentsProvider);
    final limits = ref.watch(workAgentLimitsProvider);
    return ListenableBuilder(
      listenable: runtime,
      builder: (context, _) {
        final all = runtime.records
            .where((r) => r.conversationId == widget.conversationId)
            .toList();
        final selected =
            all.where((r) => r.id == _selected).firstOrNull ?? all.lastOrNull;
        final ordered = <WorkAgentRecord>[];
        void visit(WorkAgentRecord r) {
          ordered.add(r);
          if (_collapsed.contains(r.id)) return;
          for (final child in all.where((c) => c.parentId == r.id)) {
            visit(child);
          }
        }

        for (final r in all.where(
          (r) => r.parentId == null || !all.any((p) => p.id == r.parentId),
        )) {
          visit(r);
        }
        return Column(
          children: [
            ExpansionTile(
              title: const Text('子代理限制'),
              subtitle: Text(
                '深度 ${limits.maxDepth} · 直属 ${limits.maxChildren} · 同时 ${limits.maxConcurrent}',
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          _limit(
                            '最大深度',
                            limits.maxDepth,
                            0,
                            8,
                            (v) => _save(
                              WorkAgentLimits(
                                maxDepth: v,
                                maxChildren: limits.maxChildren,
                                maxConcurrent: limits.maxConcurrent,
                                maxRounds: limits.maxRounds,
                              ),
                            ),
                          ),
                          _limit(
                            '直属子任务',
                            limits.maxChildren,
                            0,
                            16,
                            (v) => _save(
                              WorkAgentLimits(
                                maxDepth: limits.maxDepth,
                                maxChildren: v,
                                maxConcurrent: limits.maxConcurrent,
                                maxRounds: limits.maxRounds,
                              ),
                            ),
                          ),
                          _limit(
                            '单个工作并发',
                            limits.maxConcurrent,
                            1,
                            16,
                            (v) => _save(
                              WorkAgentLimits(
                                maxDepth: limits.maxDepth,
                                maxChildren: limits.maxChildren,
                                maxConcurrent: v,
                                maxRounds: limits.maxRounds,
                              ),
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('子代理工具轮数'),
                              const SizedBox(width: 8),
                              DropdownButton<int>(
                                value: limits.maxRounds,
                                items:
                                    ([
                                          8,
                                          12,
                                          24,
                                          48,
                                          96,
                                          192,
                                          limits.maxRounds,
                                        ].toSet().toList()..sort())
                                        .map(
                                          (v) => DropdownMenuItem(
                                            value: v,
                                            child: Text('$v'),
                                          ),
                                        )
                                        .toList(),
                                onChanged: (v) {
                                  if (v != null)
                                    _save(
                                      WorkAgentLimits(
                                        maxDepth: limits.maxDepth,
                                        maxChildren: limits.maxChildren,
                                        maxConcurrent: limits.maxConcurrent,
                                        maxRounds: v,
                                      ),
                                    );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '根任务深度为 0；直属数量按累计创建计算，结束后不释放名额。设置用于新任务。深度 2、直属 3 时最多为 1 + 3 + 9 = 13 个节点。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            WorkAgentModelPoolSettings(conversationId: widget.conversationId),
            const Divider(height: 1),
            if (all.isEmpty)
              const Expanded(child: _EmptyAgents())
            else
              Expanded(
                child: LayoutBuilder(
                  builder: (context, size) {
                    final tree = ListView.builder(
                      itemCount: ordered.length,
                      itemBuilder: (context, i) {
                        final r = ordered[i];
                        final hasChildren = all.any((c) => c.parentId == r.id);
                        final collapsed = _collapsed.contains(r.id);
                        final descendants = all.where((child) {
                          var parent = child.parentId;
                          while (parent != null) {
                            if (parent == r.id) return true;
                            parent = runtime.record(parent)?.parentId;
                          }
                          return false;
                        }).toList();
                        final running = descendants
                            .where((c) => c.status == WorkAgentStatus.running)
                            .length;
                        final waiting = descendants
                            .where(
                              (c) =>
                                  c.status == WorkAgentStatus.waiting ||
                                  c.status == WorkAgentStatus.queued,
                            )
                            .length;
                        final completed = descendants
                            .where((c) => c.status == WorkAgentStatus.completed)
                            .length;
                        return AgentClusterCard(
                          agent: r,
                          selected: selected?.id == r.id,
                          collapsed: collapsed,
                          summary: '运行 $running · 等待 $waiting · 完成 $completed',
                          onTap: () => setState(() => _selected = r.id),
                          onToggle: !hasChildren
                              ? null
                              : () => setState(() {
                                  if (collapsed) {
                                    _collapsed.remove(r.id);
                                  } else {
                                    _collapsed.add(r.id);
                                  }
                                }),
                        );
                      },
                    );
                    final detail = selected == null
                        ? const SizedBox.shrink()
                        : _detail(context, runtime, selected);
                    return WorkbenchSplitView(
                      first: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                            child: Row(
                              children: [
                                const Icon(Icons.hub_outlined, size: 18),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    '代理集群',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${all.where((r) => !r.external).length} 个子任务',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          Expanded(child: tree),
                        ],
                      ),
                      second: detail,
                      initialWidth: 320,
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _limit(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> changed,
  ) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label),
      const SizedBox(width: 8),
      DropdownButton<int>(
        value: value,
        items: [
          for (var i = min; i <= max; i++)
            DropdownMenuItem(value: i, child: Text('$i')),
        ],
        onChanged: (v) {
          if (v != null) changed(v);
        },
      ),
    ],
  );
  Future<void> _save(WorkAgentLimits limits) async {
    try {
      await ref.read(workAgentLimitsProvider.notifier).save(limits);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Widget _detail(
    BuildContext context,
    WorkAgentRuntime runtime,
    WorkAgentRecord r,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(r.activity, style: theme.textTheme.titleSmall),
              ),
              if (!r.terminal)
                PopupMenuButton<bool>(
                  tooltip: '取消代理',
                  icon: const Icon(Icons.stop_circle_outlined, size: 20),
                  onSelected: (subtree) =>
                      runtime.cancel(r.id, subtree: subtree),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: false, child: Text('取消此代理')),
                    const PopupMenuItem(value: true, child: Text('取消整个子树')),
                  ],
                ),
            ],
          ),
        ),
        Expanded(
          child: SelectionArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              children: [
                Text(r.task, style: theme.textTheme.bodyMedium),
                if (r.role != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '角色 · ${r.role!.name}',
                    style: theme.textTheme.titleSmall,
                  ),
                  if (r.roleReason.isNotEmpty)
                    Text(r.roleReason, style: theme.textTheme.bodySmall),
                ],
                const SizedBox(height: 8),
                Text(
                  '${r.model} · 深度 ${r.depth} · 直属 ${r.childrenCreated}/${r.limits.maxChildren}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  r.restored && r.rounds == 0
                      ? '旧版记录未保存完整轮次与用量'
                      : '输入 ${r.inputTokens} / 输出 ${r.outputTokens} token · ${r.rounds} 轮${r.cost == null ? '' : ' · ${r.cost!.toStringAsFixed(4)} ${r.currency ?? ''}'}',
                  style: theme.textTheme.bodySmall,
                ),
                if (!r.external && r.contextTokens > 0)
                  Text(
                    '当前独立上下文约 ${r.contextTokens} token',
                    style: theme.textTheme.bodySmall,
                  ),
                if (r.restored)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '历史记录：上下文和执行连接未恢复。',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (r.files.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('修改文件', style: theme.textTheme.titleSmall),
                  ...r.files.map(
                    (p) => Text(p, style: theme.textTheme.bodySmall),
                  ),
                ],
                if (r.output.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('当前输出', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(r.output),
                ],
                if (r.logs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('工具活动', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  ...r.logs.reversed
                      .take(24)
                      .map(
                        (log) => Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            log,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                ],
              ],
            ),
          ),
        ),
        if (!r.restored && r.status != WorkAgentStatus.cancelled)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _message,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: '发送补充信息或后续任务',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(runtime, r),
                  ),
                ),
                IconButton(
                  tooltip: '发送后续任务',
                  onPressed: () => _send(runtime, r),
                  icon: const Icon(Icons.send_outlined),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _send(WorkAgentRuntime runtime, WorkAgentRecord r) {
    try {
      runtime.followup(r.id, _message.text);
      _message.clear();
    } catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _EmptyAgents extends StatelessWidget {
  const _EmptyAgents();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 36,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          const Text('子代理协作'),
          const SizedBox(height: 8),
          const Text(
            '让主任务把独立工作分配给子代理。这里显示完整任务树、真实工具活动和结果；子任务完成后自动汇报。',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}
