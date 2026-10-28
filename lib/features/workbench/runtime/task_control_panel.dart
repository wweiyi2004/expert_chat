import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_toast.dart';
import '../../../core/settings_form_style.dart';
import '../../../state/chat_controller.dart';
import '../../../state/task_acceptance_provider.dart';
import '../logs/work_memory_card.dart';
import '../../../data/task_budget_prefs.dart';

String _budgetCount(Object? count) =>
    count is num ? TaskBudgetPrefs.describeCount(count.toInt()) : '—';

String acceptanceStatusLabel(TaskAcceptanceStatus status) => switch (status) {
  TaskAcceptanceStatus.running => '执行中',
  TaskAcceptanceStatus.replyComplete => '答复已结束，工具待结束',
  TaskAcceptanceStatus.toolComplete => '工具已结束，答复待结束',
  TaskAcceptanceStatus.waitingAcceptance => '等待验收',
  TaskAcceptanceStatus.accepted => '验收通过',
  TaskAcceptanceStatus.failed => '检查未通过',
};

class TaskAdvancedOptions extends ConsumerWidget {
  const TaskAdvancedOptions({super.key, required this.conversationId});
  final String conversationId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ExpansionTile(
    key: const ValueKey('advanced-task-options'),
    title: const Text('高级任务选项'),
    subtitle: const Text('固定约束、验收条件与仓库规则'),
    children: [
      ListTile(
        title: const Text('固定任务约束'),
        subtitle: const Text('仅由你修改，下一工具轮读取'),
        leading: const Icon(Icons.push_pin_outlined),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => WorkMemoryEditDialog(conversationId: conversationId),
        ),
      ),
      ListTile(
        title: const Text('下一任务的验收条件'),
        subtitle: const Text('任务开始时锁定；未设自动检查时由你确认'),
        leading: const Icon(Icons.fact_check_outlined),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => TaskCriteriaDialog(conversationId: conversationId),
        ),
      ),
      ListTile(
        title: const Text('历史验收记录'),
        leading: const Icon(Icons.history),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) =>
              TaskAcceptanceHistoryDialog(conversationId: conversationId),
        ),
      ),
      ListTile(
        title: const Text('已加载的仓库规则与技能'),
        leading: const Icon(Icons.rule_folder_outlined),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) =>
              RepositorySourcesDialog(conversationId: conversationId),
        ),
      ),
      ListTile(
        title: const Text('查看任务笔记与计划'),
        leading: const Icon(Icons.notes_outlined),
        onTap: () => showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('任务笔记'),
            content: SizedBox(
              width: 600,
              child: WorkMemoryCard(
                conversationId: conversationId,
                initiallyExpanded: true,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class TaskAcceptanceHistoryDialog extends ConsumerWidget {
  const TaskAcceptanceHistoryDialog({super.key, required this.conversationId});
  final String conversationId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks =
        ref
            .watch(taskAcceptanceProvider)
            .values
            .where((task) => task.conversationId == conversationId)
            .toList()
          ..sort((a, b) => b.frozenAt.compareTo(a.frozenAt));
    return AlertDialog(
      title: const Text('历史验收记录'),
      content: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * .5,
        child: tasks.isEmpty
            ? const Center(child: Text('此会话还没有验收记录'))
            : ListView.builder(
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  return ListTile(
                    title: Text(acceptanceStatusLabel(task.status)),
                    subtitle: Text(
                      '${task.frozenAt.toLocal().toString().substring(0, 16)} · ${task.criteria.description.isEmpty ? '未填写补充说明' : task.criteria.description}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (_) => TaskAcceptanceDialog(taskId: task.taskId),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class TaskControlPanel extends ConsumerStatefulWidget {
  const TaskControlPanel({super.key, required this.conversationId});
  final String conversationId;
  @override
  ConsumerState<TaskControlPanel> createState() => _TaskControlPanelState();
}

class _TaskControlPanelState extends ConsumerState<TaskControlPanel> {
  bool busy = false;
  Future<void> _act(Future<bool> Function() action, String success) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await action();
      if (mounted) {
        AppToastMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result ? success : '尚不能继续，请核对任务状态和执行位置。')),
        );
      }
    } catch (error) {
      if (mounted) {
        AppToastMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$error'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final checkpoint = ref
        .watch(chatControllerProvider)
        .value
        ?.sessionCheckpoints[widget.conversationId];
    final task = checkpoint?.taskState ?? const <String, dynamic>{};
    final taskId = task['rootId'] as String?;
    if (taskId == null) return const SizedBox.shrink();
    final acceptance = ref.watch(taskAcceptanceProvider)[taskId];
    final storageError = ref.read(taskAcceptanceProvider.notifier).storageError;
    final budget = task['budget'] as Map? ?? const {};
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('task-lifecycle-panel'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('任务进度与验收', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (checkpoint!.phase.isNotEmpty) Text(checkpoint.phase),
            if (storageError != null)
              Text(storageError, style: TextStyle(color: colors.error)),
            if (acceptance != null) ...[
              const SizedBox(height: 8),
              Text(
                checkpoint.status == SessionExecutionStatus.cancelled
                    ? '任务已停止'
                    : checkpoint.resumeRequired
                    ? '等待核验恢复'
                    : acceptanceStatusLabel(acceptance.status),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: acceptance.hasFailure ? colors.error : colors.primary,
                ),
              ),
              Text(
                '答复：${acceptance.replyComplete ? '已结束' : '未结束'} · 工具：${acceptance.toolsComplete ? '已结束' : '未结束'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (budget.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '累计工具 ${budget['toolCalls'] ?? 0}/${_budgetCount(budget['maxToolCalls'])} 次 · 搜索 ${budget['searches'] ?? 0}/${_budgetCount(budget['maxSearches'])} 次 · 执行 ${((budget['elapsedMs'] as num? ?? 0) / 1000).round()} 秒${budget['workSeconds'] == 0 ? '（不限时）' : '/${budget['workSeconds'] ?? '—'} 秒'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (checkpoint.resumeRequired)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(busy ? '正在核验…' : '核验并恢复任务'),
                    onPressed: busy
                        ? null
                        : () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (dialog) => AlertDialog(
                                title: const Text('核验后继续'),
                                content: const Text(
                                  '请先核对原工作目录和已有结果。恢复会重新检查执行位置、权限与未确认的操作；不会自动重放旧调用。未确认操作需在日志中核验。',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialog, false),
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(dialog, true),
                                    child: const Text('检查并继续'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true && mounted) {
                              await _act(
                                () => ref
                                    .read(chatControllerProvider.notifier)
                                    .resumeSessionTask(widget.conversationId),
                                '任务已恢复',
                              );
                            }
                          },
                  ),
                if (acceptance != null)
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => TaskAcceptanceDialog(taskId: taskId),
                    ),
                    child: const Text('查看验收证据'),
                  ),
                if (acceptance != null &&
                    acceptance.status == TaskAcceptanceStatus.waitingAcceptance)
                  OutlinedButton(
                    onPressed: busy || !acceptance.machineVerified
                        ? null
                        : () => _act(
                            () => ref
                                .read(chatControllerProvider.notifier)
                                .verifyAndAcceptTask(widget.conversationId),
                            '已重新核验产物并确认通过',
                          ),
                    child: const Text('核验产物并确认通过'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TaskAcceptanceDialog extends ConsumerWidget {
  const TaskAcceptanceDialog({super.key, required this.taskId});
  final String taskId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(taskAcceptanceProvider)[taskId];
    return AlertDialog(
      title: const Text('验收条件与证据'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: task == null
                ? [const Text('没有此任务的验收记录。')]
                : [
                    Text(acceptanceStatusLabel(task.status)),
                    if (task.requiresReverification)
                      const Text('这是导入的历史证据，当前环境尚未重新核验。历史通过记录不能代替本次检查。'),
                    const SizedBox(height: 12),
                    SelectableText(
                      task.criteria.description.isEmpty
                          ? '未填写补充验收说明'
                          : task.criteria.description,
                    ),
                    const SizedBox(height: 12),
                    for (final command in task.criteria.checkIds)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SelectableText(
                          '检查：$command\n${task.checks[command] == null ? '尚无执行证据' : '退出码：${task.checks[command]!['exitCode']} · ${task.checks[command]!['provenance']}'}',
                        ),
                      ),
                    for (final path in task.criteria.artifactPaths)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SelectableText(
                          '产物：$path\n${task.artifacts[path] == null ? '尚无文件证据' : '存在：${task.artifacts[path]!['present']}\nSHA-256：${task.artifacts[path]!['sha256']}'}',
                        ),
                      ),
                    if (task.criteria.checkIds.isEmpty &&
                        task.criteria.artifactPaths.isEmpty)
                      const Text('此任务没有自动检查条件，执行结束后由你验收。'),
                    if (task.acceptedAt != null)
                      Text('人工确认：${task.acceptedAt!.toLocal()}'),
                  ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class TaskCriteriaDialog extends ConsumerStatefulWidget {
  const TaskCriteriaDialog({super.key, required this.conversationId});
  final String conversationId;
  @override
  ConsumerState<TaskCriteriaDialog> createState() => _TaskCriteriaDialogState();
}

class _TaskCriteriaDialogState extends ConsumerState<TaskCriteriaDialog> {
  late final TextEditingController description, checks, artifacts;
  bool manual = true, saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final criteria = ref
        .read(taskAcceptanceProvider.notifier)
        .draftCriteriaForConversation(widget.conversationId);
    error = ref.read(taskAcceptanceProvider.notifier).storageError;
    description = TextEditingController(text: criteria.description);
    checks = TextEditingController(text: criteria.checkIds.join('\n'));
    artifacts = TextEditingController(text: criteria.artifactPaths.join('\n'));
    manual = criteria.manualRequired;
  }

  @override
  void dispose() {
    description.dispose();
    checks.dispose();
    artifacts.dispose();
    super.dispose();
  }

  List<String> lines(String raw) => raw
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();
  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final paths = lines(artifacts.text);
      final commands = lines(checks.text);
      if (paths.length > 128 || commands.length > 64) {
        throw ArgumentError('每个任务最多配置 64 条检查命令和 128 个产物路径。');
      }
      if (paths.any(
        (p) =>
            p.startsWith('/') ||
            p.startsWith('\\') ||
            RegExp(r'^[A-Za-z]:').hasMatch(p) ||
            p.replaceAll('\\', '/').split('/').contains('..'),
      )) {
        throw ArgumentError('产物路径须位于工作目录内，不能使用绝对路径或 ..');
      }
      await ref
          .read(taskAcceptanceProvider.notifier)
          .saveDraft(
            widget.conversationId,
            AcceptanceCriteria(
              description: description.text.trim(),
              checkIds: commands,
              artifactPaths: paths,
              manualRequired: manual || (commands.isEmpty && paths.isEmpty),
            ),
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsFormStyle(
    child: AlertDialog(
      title: const Text('下一任务的验收条件'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '开始任务时锁定这些条件；保存不会改变正在执行的任务，也不会立即运行命令。普通写作可以只填写说明并保留人工确认。',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: description,
                minLines: 2,
                maxLines: 5,
                maxLength: 6000,
                decoration: const InputDecoration(
                  labelText: '验收说明',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: checks,
                minLines: 2,
                maxLines: 5,
                maxLength: 12000,
                decoration: const InputDecoration(
                  labelText: '必须通过的检查命令（每行一条）',
                  helperText: '例如 flutter test；按确切命令及真实退出码核验',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: artifacts,
                minLines: 2,
                maxLines: 5,
                maxLength: 6000,
                decoration: const InputDecoration(
                  labelText: '必须存在的产物（相对路径，每行一条）',
                  helperText: '例如 output/report.pdf',
                  alignLabelWithHint: true,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('检查通过后仍由我确认'),
                value: manual,
                onChanged: saving ? null : (v) => setState(() => manual = v),
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (ref.read(taskAcceptanceProvider.notifier).storageError !=
                  null)
                TextButton.icon(
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('复制原始验收记录以便恢复'),
                  onPressed: () async {
                    final raw = ref
                        .read(taskAcceptanceProvider.notifier)
                        .rawStoredValue;
                    await Clipboard.setData(ClipboardData(text: '$raw'));
                    if (context.mounted) {
                      AppToastMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('已复制原始记录')));
                    }
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}

class RepositorySourcesDialog extends ConsumerWidget {
  const RepositorySourcesDialog({super.key, required this.conversationId});
  final String conversationId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref
            .watch(chatControllerProvider)
            .value
            ?.sessionCheckpoints[conversationId]
            ?.taskState ??
        const <String, dynamic>{};
    final actors = state['repositorySources'] as Map? ?? const {};
    return AlertDialog(
      title: const Text('已加载的仓库规则与技能'),
      content: SizedBox(
        width: 660,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('这里显示本任务实际加载的来源与版本。仓库文字仅提供任务指导，不会增加文件、命令或联网权限。'),
              const SizedBox(height: 12),
              if (actors.isEmpty)
                const Text('当前任务尚无已加载来源。进入工作任务后会在授权目录内读取规则；可用 \$技能名 显式选择仓库技能。'),
              for (final actor in actors.entries) ...[
                Text(
                  actor.key == 'main' ? '主代理' : '代理 ${actor.key}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                for (final source
                    in ((actor.value as Map)['sources'] as List? ?? const []))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: SelectableText(
                      '${source['kind']} · ${source['path']}\n范围：${source['scope']}\nSHA-256：${source['hash']}',
                    ),
                  ),
                for (final warning
                    in ((actor.value as Map)['warnings'] as List? ?? const []))
                  Text(
                    '$warning',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                for (final skill
                    in ((actor.value as Map)['skills'] as List? ?? const []))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      '可选技能：\$${skill['name']} · ${skill['description']}',
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
