import 'package:flutter/material.dart';

import '../../../data/context_prefs.dart';

class ContextSettingsCard extends StatelessWidget {
  const ContextSettingsCard({
    super.key,
    required this.prefs,
    required this.onChanged,
  });

  final ContextPrefs prefs;
  final ValueChanged<ContextPrefs> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final windows = <int>{
      8192,
      16384,
      32768,
      65536,
      128000,
      200000,
      256000,
      1000000,
      prefs.contextWindowTokens,
    }.toList()..sort();
    final outputOptions = <int>{
      1024,
      2048,
      4096,
      8192,
      16384,
      32768,
      65536,
      131072,
      262144,
      384000,
      prefs.reservedOutputTokens,
    }.where((v) => v < prefs.contextWindowTokens).toList()..sort();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动管理上下文'),
              subtitle: const Text('只裁剪发送给模型的临时请求，不修改已保存的聊天记录。'),
              value: prefs.enabled,
              onChanged: (value) => onChanged(prefs.copyWith(enabled: value)),
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<int>(
              key: ValueKey('context-window-${prefs.contextWindowTokens}'),
              isExpanded: true,
              initialValue: prefs.contextWindowTokens,
              decoration: const InputDecoration(labelText: '模型上下文窗口'),
              items: [
                for (final value in windows)
                  DropdownMenuItem(
                    value: value,
                    child: Text(_formatTokens(value)),
                  ),
              ],
              onChanged: prefs.enabled
                  ? (value) {
                      if (value == null) return;
                      final maxReserved = value - 1024;
                      onChanged(
                        prefs.copyWith(
                          contextWindowTokens: value,
                          reservedOutputTokens:
                              prefs.reservedOutputTokens > maxReserved
                              ? maxReserved
                              : prefs.reservedOutputTokens,
                        ),
                      );
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: ValueKey(
                'context-output-${prefs.contextWindowTokens}-'
                '${prefs.reservedOutputTokens}',
              ),
              isExpanded: true,
              initialValue: prefs.reservedOutputTokens,
              decoration: const InputDecoration(labelText: '为回复预留'),
              items: [
                for (final value in outputOptions)
                  DropdownMenuItem(
                    value: value,
                    child: Text(_formatTokens(value)),
                  ),
              ],
              onChanged: prefs.enabled
                  ? (value) {
                      if (value != null) {
                        onChanged(prefs.copyWith(reservedOutputTokens: value));
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Text('最多携带历史消息')),
                Text(
                  '${prefs.maxHistoryMessages} 条',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              value: prefs.maxHistoryMessages.toDouble(),
              min: 4,
              max: 64,
              divisions: 15,
              label: '${prefs.maxHistoryMessages} 条',
              onChanged: prefs.enabled
                  ? (value) => onChanged(
                      prefs.copyWith(
                        maxHistoryMessages: ((value / 4).round() * 4).clamp(
                          4,
                          64,
                        ),
                      ),
                    )
                  : null,
            ),
            Text(
              '当前输入预算约为 ${_formatTokens(prefs.inputBudgetTokens)}。'
              '开启后：优先保留最近对话；装不下时会自动省略较早消息并生成简短历史摘要，'
              '顶栏可查看用量与是否已压缩。'
              'Token 为跨模型保守估算，实际计费以服务商返回值为准。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTokens(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M Token';
    }
    if (value >= 1000) {
      final digits = value % 1000 == 0 ? 0 : 1;
      return '${(value / 1000).toStringAsFixed(digits)}K Token';
    }
    return '$value Token';
  }
}
