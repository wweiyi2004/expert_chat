import 'package:flutter/material.dart';
import '../../../data/task_budget_prefs.dart';

class TaskBudgetEditor extends StatelessWidget {
  const TaskBudgetEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final TaskBudgetPrefs value;
  final ValueChanged<TaskBudgetPrefs> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('模型响应等待', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      _number(
        '工作模式首次响应等待（秒）',
        value.workResponseTimeoutSeconds,
        30,
        600,
        (n) => value.copyWith(workResponseTimeoutSeconds: n),
      ),
      const Text(
        '默认 120 秒，适用于工作主代理和子代理的模型请求。这里只控制收到响应头前的等待；连接建立及流式输出空闲超时独立计算。普通聊天仍使用原有等待时间。设置变更在主任务下一完整工具轮生效。',
      ),
      const SizedBox(height: 20),
      Text('可选任务限制', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      DropdownButtonFormField<TaskBudgetPreset>(
        key: ValueKey(value.preset),
        initialValue: value.preset,
        decoration: const InputDecoration(labelText: '预算预设'),
        items: [
          for (final p in TaskBudgetPreset.values)
            DropdownMenuItem(
              value: p,
              child: Text(TaskBudgetPrefs.forPreset(p).label),
            ),
        ],
        onChanged: (p) {
          if (p != null) {
            onChanged(
              TaskBudgetPrefs.forPreset(p).copyWith(
                workResponseTimeoutSeconds: value.workResponseTimeoutSeconds,
              ),
            );
          }
        },
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '执行时间：${value.workSeconds == 0 ? '不限' : '${value.workSeconds} 秒'} · '
          '搜索 ${TaskBudgetPrefs.describeCount(value.maxSearches)} 次 · '
          '工具调用 ${TaskBudgetPrefs.describeCount(value.maxToolCalls)} 次。'
          '\n达到限制后，将尝试根据已有结果整理回答。',
        ),
      ),
      const ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('限制如何计算'),
        children: [
          Text(
            '后台续接与可控恢复保留已用额度。主代理和子代理共享计数，并行执行按实际经过时间计一次；暂停或等待人工批准时，没有其他代理在执行才停计时。正常回答输出不计入执行时间。部分服务无法统计搜索次数，仍会限制执行时间。增加轮次不会重置时间和工具次数额度。',
          ),
        ],
      ),
      if (value.preset == TaskBudgetPreset.custom) ...[
        _number(
          '执行时间（秒，0 为不限）',
          value.workSeconds,
          0,
          3600,
          (n) => TaskBudgetPrefs(
            workSeconds: n,
            workResponseTimeoutSeconds: value.workResponseTimeoutSeconds,
            maxSearches: value.maxSearches,
            maxToolCalls: value.maxToolCalls,
          ),
        ),
        _count(
          '搜索次数',
          value.maxSearches,
          (n) => TaskBudgetPrefs(
            workSeconds: value.workSeconds,
            workResponseTimeoutSeconds: value.workResponseTimeoutSeconds,
            maxSearches: n,
            maxToolCalls: value.maxToolCalls,
          ),
        ),
        _count(
          '工具调用次数',
          value.maxToolCalls,
          (n) => TaskBudgetPrefs(
            workSeconds: value.workSeconds,
            maxSearches: value.maxSearches,
            maxToolCalls: n,
            workResponseTimeoutSeconds: value.workResponseTimeoutSeconds,
          ),
        ),
      ],
    ],
  );

  Widget _number(
    String label,
    int current,
    int min,
    int max,
    TaskBudgetPrefs Function(int) update,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextFormField(
      key: ValueKey('$label-$current'),
      initialValue: '$current',
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        helperText: '$min–$max，提交后保存',
      ),
      onFieldSubmitted: (raw) {
        final n = int.tryParse(raw);
        if (n != null) onChanged(update(n.clamp(min, max)));
      },
    ),
  );

  /// Blank means unlimited; explicit counts stay below the legacy 192 cap.
  Widget _count(
    String label,
    int current,
    TaskBudgetPrefs Function(int) update,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextFormField(
      key: ValueKey('$label-$current'),
      initialValue: TaskBudgetPrefs.isUnlimited(current) ? '' : '$current',
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        hintText: '不限',
        helperText: '留空为不限；0–${TaskBudgetPrefs.maxCount - 1}，提交后保存',
      ),
      onFieldSubmitted: (raw) {
        if (raw.trim().isEmpty) {
          onChanged(update(TaskBudgetPrefs.unlimited));
          return;
        }
        final n = int.tryParse(raw.trim());
        if (n != null) onChanged(update(TaskBudgetPrefs.count(n)));
      },
    ),
  );
}
