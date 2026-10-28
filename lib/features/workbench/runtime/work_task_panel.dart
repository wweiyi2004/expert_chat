import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/work_task_runtime.dart';
import '../../../state/chat_controller.dart';
import '../../../state/task_overview.dart';
import '../../../state/work_changes.dart';
import '../../../data/models.dart' show MessageRole;
import 'task_control_panel.dart';

/// Fits either the workbench detail pane or a modal sheet on smaller screens.
class WorkTaskPanel extends ConsumerWidget {
  const WorkTaskPanel({
    super.key,
    required this.conversationId,
    this.onOpenFile,
  });

  final String conversationId;
  final ValueChanged<WorkFileChange>? onOpenFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref
        .watch(workTaskRuntimeProvider)
        .where((r) => r.conversationId == conversationId)
        .toList();
    final overview = ref
        .watch(taskOverviewProvider)
        .where((t) => t.session == conversationId)
        .firstOrNull;
    final conversation = ref
        .watch(chatControllerProvider)
        .value
        ?.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final assistant = conversation?.activePath
        .where((m) => m.role == MessageRole.assistant)
        .lastOrNull;
    final files = assistant == null
        ? <WorkFileChange>[]
        : finalDeliveryFiles(
            ref.watch(workChangesProvider),
            conversationId,
            assistant.id,
          );
    final checkpoint = ref
        .watch(chatControllerProvider)
        .value
        ?.sessionCheckpoints[conversationId];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('成果与检查', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          overview?.execution ?? '还没有开始任务',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        if (files.isEmpty)
          Text(
            '还没有交付文件。完成任务后，最终文件会集中显示在这里。',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else ...[
          Text(
            '交付文件 · ${files.length}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (final file in files)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insert_drive_file_outlined, size: 20),
              title: Text(file.path),
              trailing: onOpenFile == null
                  ? null
                  : const Icon(Icons.open_in_new, size: 16),
              onTap: onOpenFile == null ? null : () => onOpenFile!(file),
            ),
        ],
        const SizedBox(height: 16),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('验收与任务设置'),
          initiallyExpanded: checkpoint?.resumeRequired == true,
          children: [TaskControlPanel(conversationId: conversationId)],
        ),
        if (records.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('运行记录 · ${records.length}'),
            children: [
              for (final record in records.reversed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _TaskCard(record: record),
                ),
            ],
          ),
      ],
    );
  }
}

class _TaskStatusIcon extends StatelessWidget {
  const _TaskStatusIcon({required this.status});
  final WorkTaskStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Icon(
      switch (status) {
        WorkTaskStatus.running => Icons.play_circle_outline,
        WorkTaskStatus.waitingForApproval => Icons.pending_actions,
        WorkTaskStatus.completed => Icons.check_circle_outline,
        WorkTaskStatus.failed => Icons.error_outline,
        WorkTaskStatus.cancelled => Icons.cancel_outlined,
        WorkTaskStatus.interrupted => Icons.pause_circle_outline,
      },
      size: 18,
      color: status == WorkTaskStatus.failed ? colors.error : colors.primary,
    );
  }
}

class _TaskCard extends ConsumerWidget {
  const _TaskCard({required this.record});
  final WorkTaskRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final runtime = ref.read(workTaskRuntimeProvider.notifier);
    final started = record.startedAt.toLocal();
    final time =
        '${started.month}/${started.day} '
        '${started.hour.toString().padLeft(2, '0')}:'
        '${started.minute.toString().padLeft(2, '0')}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _TaskStatusIcon(status: record.status),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    record.title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (record.status.isActive && runtime.canStop(record.id))
                  TextButton.icon(
                    onPressed: record.stopRequested
                        ? null
                        : () => runtime.stop(record.id),
                    icon: const Icon(Icons.stop_circle_outlined, size: 16),
                    label: Text(record.stopRequested ? '正在停止' : '停止'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${record.status == WorkTaskStatus.completed ? (record.exitCode == null ? '答复已结束' : '工具已结束') : record.status.label} · $time'
              '${record.exitCode == null ? '' : ' · 退出码 ${record.exitCode}'}',
              style: theme.textTheme.bodySmall,
            ),
            if (record.detail case final detail?) ...[
              const SizedBox(height: 6),
              Text(
                detail,
                style: theme.textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (record.message case final message?) ...[
              const SizedBox(height: 6),
              Text(message, style: theme.textTheme.bodySmall),
            ],
            if (record.logs.isNotEmpty) ...[
              const SizedBox(height: 10),
              if (record.logsTruncated)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text('仅显示最近的输出', style: TextStyle(fontSize: 11)),
                ),
              _LiveLog(logs: record.logs),
            ] else if (!record.status.isActive) ...[
              const SizedBox(height: 8),
              Text(
                '完整工具结果可在会话中查看；实时日志不跨重启保留。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LiveLog extends StatefulWidget {
  const _LiveLog({required this.logs});
  final List<WorkTaskLog> logs;

  @override
  State<_LiveLog> createState() => _LiveLogState();
}

class _LiveLogState extends State<_LiveLog> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _LiveLog oldWidget) {
    super.didUpdateWidget(oldWidget);
    final follow =
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.offset < 48;
    if (follow && oldWidget.logs != widget.logs) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 300),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          child: SelectableText.rich(
            TextSpan(
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
              children: [
                for (final log in widget.logs)
                  TextSpan(
                    text: log.text,
                    style: TextStyle(
                      color: log.isStderr
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface,
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
