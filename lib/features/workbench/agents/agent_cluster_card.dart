import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../domain/workbench/agents/work_agent_runtime.dart';

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
    final colors = Theme.of(context).colorScheme;
    final status = switch (agent.status) {
      WorkAgentStatus.running => '执行中',
      WorkAgentStatus.queued => '排队中',
      WorkAgentStatus.waiting => '等待子任务',
      WorkAgentStatus.completed => '已完成',
      WorkAgentStatus.failed => '执行失败',
      WorkAgentStatus.cancelled => '已取消',
      WorkAgentStatus.interrupted => '已中断',
    };
    final statusColor = agent.status == WorkAgentStatus.failed
        ? colors.error
        : agent.terminal
        ? colors.onSurfaceVariant
        : colors.primary;
    final icon = agent.external
        ? Icons.account_tree_outlined
        : switch (agent.role?.id) {
            'coding' => Icons.code_rounded,
            'review' => Icons.fact_check_outlined,
            'research' => Icons.travel_explore,
            'testing' => Icons.bug_report_outlined,
            'writing' => Icons.edit_note_rounded,
            _ => Icons.smart_toy_outlined,
          };
    return Padding(
      padding: EdgeInsets.fromLTRB(
        8 + (agent.depth * 12).clamp(0, 48).toDouble(),
        4,
        8,
        4,
      ),
      child: Material(
        color: selected
            ? colors.primaryContainer.withValues(alpha: .42)
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected
                ? colors.primary.withValues(alpha: .45)
                : colors.outlineVariant.withValues(alpha: .7),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 18, color: colors.onSurface),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        agent.external ? '主代理' : agent.role?.name ?? '通用执行',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${agent.rounds.toString().padLeft(2, '0')} 轮',
                      style: TextStyle(
                        fontSize: 10,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.subdirectory_arrow_right_rounded,
                      size: 15,
                      color: colors.outline,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        agent.task.replaceAll('\n', ' '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: agent.activity,
                      child: _ActivityDots(
                        status: agent.status,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$status · ${agent.model}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: statusColor),
                      ),
                    ),
                    if (onToggle != null)
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: collapsed ? '展开子代理' : '折叠子代理',
                          onPressed: onToggle,
                          icon: Icon(
                            collapsed ? Icons.chevron_right : Icons.expand_more,
                            size: 17,
                          ),
                        ),
                      ),
                  ],
                ),
                if (collapsed && summary.isNotEmpty)
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivityDots extends StatefulWidget {
  const _ActivityDots({required this.status, required this.color});
  final WorkAgentStatus status;
  final Color color;
  @override
  State<_ActivityDots> createState() => _ActivityDotsState();
}

class _ActivityDotsState extends State<_ActivityDots>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  @override
  void initState() {
    super.initState();
    _update();
  }

  void _update() {
    if (widget.status == WorkAgentStatus.running) {
      _motion.repeat();
    } else {
      _motion.stop();
    }
  }

  @override
  void didUpdateWidget(covariant _ActivityDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _update();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 42,
    height: 22,
    child: AnimatedBuilder(
      animation: _motion,
      builder: (_, _) => CustomPaint(
        painter: _DotsPainter(
          widget.color,
          MediaQuery.disableAnimationsOf(context) ? 0 : _motion.value,
          widget.status,
        ),
      ),
    ),
  );
}

class _DotsPainter extends CustomPainter {
  const _DotsPainter(this.color, this.phase, this.status);
  final Color color;
  final double phase;
  final WorkAgentStatus status;
  @override
  void paint(Canvas canvas, Size size) {
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 6; col++) {
        final alpha = status == WorkAgentStatus.running
            ? .2 +
                  .7 *
                      (1 +
                          math.sin(phase * math.pi * 2 - col * .8 - row * .4)) /
                      2
            : status == WorkAgentStatus.completed
            ? .8
            : .25;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(col * 7, row * 7 + 1, 4, 4),
            const Radius.circular(1.2),
          ),
          Paint()..color = color.withValues(alpha: alpha),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter old) =>
      color != old.color || phase != old.phase || status != old.status;
}
