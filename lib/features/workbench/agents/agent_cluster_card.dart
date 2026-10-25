import 'package:flutter/material.dart';
import '../../../domain/workbench/agents/work_agent_runtime.dart';
import '../../../core/prototype_widgets.dart';
import '../../chat/widgets/execution_status_indicator.dart';

class AgentClusterCard extends StatelessWidget {
  const AgentClusterCard({
    super.key,
    required this.agent,
    required this.selected,
    required this.onTap,
    this.onToggle,
    this.collapsed = false,
    this.summary = '',
  });
  final WorkAgentRecord agent;
  final bool selected, collapsed;
  final String summary;
  final VoidCallback onTap;
  final VoidCallback? onToggle;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    final status = switch (agent.status) {
      WorkAgentStatus.running ||
      WorkAgentStatus.waiting => ExecutionVisualStatus.running,
      WorkAgentStatus.queued => ExecutionVisualStatus.queued,
      WorkAgentStatus.completed => ExecutionVisualStatus.completed,
      WorkAgentStatus.failed => ExecutionVisualStatus.failed,
      WorkAgentStatus.cancelled ||
      WorkAgentStatus.interrupted => ExecutionVisualStatus.paused,
    };
    final label = switch (agent.status) {
      WorkAgentStatus.waiting => '等待子任务',
      WorkAgentStatus.cancelled => '已取消',
      WorkAgentStatus.interrupted => '已中断',
      _ => status.label,
    };
    final role = agent.external ? '主代理' : agent.role?.name ?? '通用执行';
    final details =
        '${agent.model} · ${agent.rounds} 轮 · ${agent.activity}${agent.auxiliaryActivity.isEmpty ? '' : ' · 辅助验收：${agent.auxiliaryActivity}'}';
    return Padding(
      padding: EdgeInsets.only(
        left: 8 + (agent.depth * 12).clamp(0, 48).toDouble(),
        right: 8,
      ),
      child: Semantics(
        selected: selected,
        button: true,
        label: '$role · ${agent.task} · $label · $details',
        child: Material(
          color: selected ? c.panel : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: details,
                          child: Text(
                            role,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: details,
                        child: ExecutionStatusCapsule(
                          status: status,
                          label: label,
                        ),
                      ),
                      if (onToggle != null)
                        PrototypeIconButton(
                          icon: collapsed
                              ? Icons.chevron_right
                              : Icons.expand_more,
                          onPressed: onToggle,
                          tooltip: collapsed ? '展开子代理' : '折叠子代理',
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    agent.task.replaceAll('\n', ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      color: c.muted,
                    ),
                  ),
                  if (collapsed && summary.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: c.faint,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
