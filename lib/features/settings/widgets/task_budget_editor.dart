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
      Text('任务执行预算', style: Theme.of(context).textTheme.titleMedium),
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
          if (p != null) onChanged(TaskBudgetPrefs.forPreset(p));
        },
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '规划与工具执行最多 ${value.workSeconds} 秒 · '
          '${value.maxSearches} 次搜索 · ${value.maxToolCalls} 次工具调用。'
          '\n达到限制后，将尝试根据已有结果整理回答。',
        ),
      ),
      const ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('限制如何计算'),
        children: [Text('正常回答输出不计入执行时间。部分服务无法统计搜索次数，仍会限制执行时间。')],
      ),
      if (value.preset == TaskBudgetPreset.custom) ...[
        _number(
          '执行时间（秒）',
          value.workSeconds,
          30,
          3600,
          (n) => TaskBudgetPrefs(
            workSeconds: n,
            maxSearches: value.maxSearches,
            maxToolCalls: value.maxToolCalls,
          ),
        ),
        _number(
          '搜索次数',
          value.maxSearches,
          0,
          192,
          (n) => TaskBudgetPrefs(
            workSeconds: value.workSeconds,
            maxSearches: n,
            maxToolCalls: value.maxToolCalls,
          ),
        ),
        _number(
          '工具调用次数',
          value.maxToolCalls,
          0,
          192,
          (n) => TaskBudgetPrefs(
            workSeconds: value.workSeconds,
            maxSearches: value.maxSearches,
            maxToolCalls: n,
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
}
