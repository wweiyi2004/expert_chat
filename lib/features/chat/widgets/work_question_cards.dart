import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models.dart';
import '../../../state/work_questions.dart';
import '../../../state/work_agents.dart';

class WorkQuestionCards extends ConsumerWidget {
  const WorkQuestionCards({
    super.key,
    required this.conversationId,
    required this.message,
  });
  final String conversationId;
  final ChatMessage message;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref
        .watch(workQuestionsProvider)
        .where(
          (q) =>
              q.conversationId == conversationId && q.assistantId == message.id,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final activity in message.searchActivities.where(
          (a) => a.toolName == workQuestionTool.name && a.resultText != null,
        ))
          _AnsweredQuestions(activity: activity),
        for (final request in pending)
          _QuestionForm(key: ValueKey(request.id), request: request),
      ],
    );
  }
}

class _AnsweredQuestions extends StatelessWidget {
  const _AnsweredQuestions({required this.activity});
  final SearchActivity activity;
  @override
  Widget build(BuildContext context) {
    Map? result;
    try {
      result = jsonDecode(activity.resultText!) as Map;
    } catch (_) {
      return const SizedBox.shrink();
    }
    final cancelled = result['cancelled'] == true;
    final answers = result['answers'];
    final descriptions = <String>[];
    final titles = <String, String>{};
    try {
      final args = jsonDecode(activity.toolArguments ?? '{}') as Map;
      for (final q in args['questions'] as List? ?? []) {
        titles[q['id'] as String] = q['question'] as String;
      }
    } catch (_) {
      /* Older activity records can omit the question arguments. */
    }
    if (answers is Map)
      for (final entry in answers.entries) {
        final value = entry.value;
        if (value is Map) {
          final chosen = (value['selected'] as List? ?? []).join('、');
          final text = value['text'] as String? ?? '';
          descriptions.add(
            [
              if (titles[entry.key] != null) titles[entry.key]!,
              if (chosen.isNotEmpty) chosen,
              if (text.isNotEmpty) text,
              if (chosen.isEmpty && text.isEmpty) '已跳过',
            ].join(' · '),
          );
        }
      }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ExpansionTile(
        leading: Icon(
          cancelled ? Icons.pause_circle_outline : Icons.task_alt,
          size: 19,
        ),
        title: Text(
          cancelled ? '提问已取消' : '已回答 · ${descriptions.length} 项',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SelectableText(descriptions.join('\n')),
          ),
        ],
      ),
    );
  }
}

class _QuestionForm extends ConsumerStatefulWidget {
  const _QuestionForm({super.key, required this.request});
  final PendingWorkQuestion request;
  @override
  ConsumerState<_QuestionForm> createState() => _QuestionFormState();
}

class _QuestionFormState extends ConsumerState<_QuestionForm> {
  late final _inputs = {
    for (final q in widget.request.questions) q.id: TextEditingController(),
  };
  final _selected = <String, Set<String>>{};
  String? _error;
  @override
  void dispose() {
    for (final input in _inputs.values) {
      input.dispose();
    }
    super.dispose();
  }

  void _submit() {
    try {
      ref.read(workQuestionsProvider.notifier).answer(widget.request.id, {
        for (final q in widget.request.questions)
          q.id: {
            'selected': (_selected[q.id] ?? {}).toList(),
            'text': _inputs[q.id]!.text.trim(),
          },
      });
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final sourceAgent = widget.request.sourceAgentId == null
        ? null
        : ref.watch(workAgentsProvider).record(widget.request.sourceAgentId!);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.primary.withValues(alpha: .22)),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 18,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text('想确认一下', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                Text(
                  '${widget.request.questions.length} 个问题',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            if (widget.request.sourceAgentId != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '来自子代理：${sourceAgent?.task ?? widget.request.sourceAgentId}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.tertiary),
                ),
              ),
            for (final q in widget.request.questions) ...[
              const SizedBox(height: 18),
              Text(
                q.question,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 5),
              Text(
                q.required
                    ? (q.multiple ? '可多选，也可以补充说明' : '请选择或输入你的想法')
                    : '可选，留空即可跳过',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (q.options.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final option in q.options)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Material(
                      color: (_selected[q.id]?.contains(option) ?? false)
                          ? colors.primaryContainer.withValues(alpha: .48)
                          : colors.surfaceContainerLow,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: (_selected[q.id]?.contains(option) ?? false)
                              ? colors.primary.withValues(alpha: .45)
                              : colors.outlineVariant.withValues(alpha: .5),
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() {
                          final values = _selected.putIfAbsent(q.id, () => {});
                          if (values.contains(option)) {
                            values.remove(option);
                          } else {
                            if (!q.multiple) values.clear();
                            values.add(option);
                          }
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 11,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                (_selected[q.id]?.contains(option) ?? false)
                                    ? Icons.check_circle_rounded
                                    : Icons.circle_outlined,
                                size: 18,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  option,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 5),
              TextField(
                controller: _inputs[q.id],
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: q.options.isEmpty ? '说说你的想法…' : '补充说明，或填写其他答案…',
                  isDense: true,
                ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: TextStyle(color: colors.error)),
              ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.request.questions.every((q) => !q.required))
                  TextButton(
                    onPressed: () {
                      _selected.clear();
                      for (final c in _inputs.values) {
                        c.clear();
                      }
                      _submit();
                    },
                    child: const Text('跳过'),
                  ),
                FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 17),
                  label: const Text('提交回答'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
