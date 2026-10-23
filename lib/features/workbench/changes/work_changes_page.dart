import '../workbench_split_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/workbench/changes/line_diff.dart';
import '../../../state/work_changes.dart';

export '../../../domain/workbench/changes/work_file_change.dart';

class WorkChangesPage extends ConsumerStatefulWidget {
  const WorkChangesPage({
    super.key,
    required this.conversationId,
    required this.restore,
    this.embedded = false,
  });

  final String conversationId;
  final WorkChangeRestore restore;
  final bool embedded;

  @override
  ConsumerState<WorkChangesPage> createState() => _WorkChangesPageState();
}

class _WorkChangesPageState extends ConsumerState<WorkChangesPage> {
  String? _selectedId;
  String? _restoringId;
  String? _error;

  Future<void> _restore(WorkFileChange change) async {
    setState(() {
      _restoringId = change.id;
      _error = null;
    });
    try {
      final notifier = ref.read(workChangesProvider.notifier);
      await widget.restore(change);
      await notifier.markReverted(change);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已恢复修改前的文件内容')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _restoringId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref
        .watch(workChangesProvider)
        .where((entry) => entry.conversationId == widget.conversationId)
        .toList()
        .reversed
        .toList();
    final selected =
        entries.where((entry) => entry.id == _selectedId).firstOrNull ??
        entries.firstOrNull;
    final colors = Theme.of(context).colorScheme;
    final body = Column(
      children: [
        FutureBuilder<void>(
          future: ref.read(workChangesProvider.notifier).ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText('改动历史加载失败：${snapshot.error}'),
              );
            }
            return snapshot.connectionState == ConnectionState.done
                ? const SizedBox.shrink()
                : const LinearProgressIndicator();
          },
        ),
        Container(
          width: double.infinity,
          color: colors.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Text(
            '${entries.length} 项文件改动 · 文件写入与已登记的交付文件',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (_error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: colors.errorContainer,
            child: SelectableText(
              _error!,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        Expanded(
          child: selected == null
              ? const Center(child: Text('这个会话还没有文件改动'))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final list = _fileList(entries, selected);
                    final detail = _ChangeDetail(
                      key: ValueKey(
                        '${selected.id}:${selected.afterHash}:${selected.reverted}',
                      ),
                      change: selected,
                      restoring: _restoringId == selected.id,
                      onRestore: _restoringId == null && selected.canRestore
                          ? () => _restore(selected)
                          : null,
                    );
                    return WorkbenchSplitView(
                      first: list,
                      second: detail,
                      breakpoint: 840,
                      initialWidth: 280,
                    );
                  },
                ),
        ),
      ],
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: const Text('工作改动')),
            body: body,
          );
  }

  Widget _fileList(List<WorkFileChange> entries, WorkFileChange selected) =>
      ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          final colors = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              selected: entry.id == selected.id,
              selectedTileColor: colors.secondaryContainer,
              leading: Icon(
                entry.reverted
                    ? Icons.undo
                    : entry.isNew
                    ? Icons.note_add_outlined
                    : Icons.edit_document,
              ),
              title: Text(
                entry.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${entry.reverted
                    ? '已撤销'
                    : entry.isNew
                    ? '新增'
                    : entry.before == entry.after
                    ? '无净改动'
                    : '修改'} · ${entry.targetLabel}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => setState(() {
                _selectedId = entry.id;
                _error = null;
              }),
            ),
          );
        },
      );
}

class _ChangeDetail extends StatefulWidget {
  const _ChangeDetail({
    super.key,
    required this.change,
    required this.restoring,
    required this.onRestore,
  });

  final WorkFileChange change;
  final bool restoring;
  final VoidCallback? onRestore;

  @override
  State<_ChangeDetail> createState() => _ChangeDetailState();
}

class _ChangeDetailState extends State<_ChangeDetail> {
  late final List<DiffLine> _lines = buildLineDiff(
    widget.change.beforeKnown ? widget.change.before : widget.change.after,
    widget.change.after,
  );
  bool _showUnchanged = false;

  @override
  Widget build(BuildContext context) {
    final change = widget.change;
    final theme = Theme.of(context);
    final added = _lines
        .where((line) => line.kind == DiffLineKind.added)
        .length;
    final removed = _lines
        .where((line) => line.kind == DiffLineKind.removed)
        .length;
    final visible = _showUnchanged || !change.beforeKnown
        ? _lines
        : _lines.where((line) => line.kind != DiffLineKind.context).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(change.path, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '${change.targetLabel} · ${change.scope}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (!change.beforeKnown) const Text('缺少原始版本，增删行数未统计'),
                  if (change.beforeKnown)
                    Text(
                      '+$added',
                      style: const TextStyle(color: Colors.green),
                    ),
                  if (change.beforeKnown)
                    Text(
                      '−$removed',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  if (change.beforeKnown)
                    FilterChip(
                      label: const Text('显示未改动行'),
                      selected: _showUnchanged,
                      onSelected: (value) =>
                          setState(() => _showUnchanged = value),
                    ),
                  OutlinedButton.icon(
                    onPressed: widget.onRestore,
                    icon: widget.restoring
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.undo, size: 18),
                    label: Text(change.reverted ? '已撤销' : '撤销该文件改动'),
                  ),
                ],
              ),
              if (change.isNew)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '新增文件暂不支持撤销：文件工具尚未提供删除能力。',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              else if (!change.reverted)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '撤销会恢复本记录的修改前内容；文件后来有其他改动时将拒绝覆盖。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('文件内容没有变化'))
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final line = visible[index];
                    final dark = theme.brightness == Brightness.dark;
                    final background = switch (line.kind) {
                      DiffLineKind.added => Colors.green.withValues(
                        alpha: dark ? .16 : .08,
                      ),
                      DiffLineKind.removed =>
                        theme.colorScheme.error.withValues(
                          alpha: dark ? .16 : .07,
                        ),
                      DiffLineKind.context => Colors.transparent,
                    };
                    return Container(
                      color: background,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 44,
                            child: Text(
                              '${line.oldLine ?? ''}',
                              textAlign: TextAlign.right,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 44,
                            child: Text(
                              '${line.newLine ?? ''}',
                              textAlign: TextAlign.right,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(switch (line.kind) {
                            DiffLineKind.added => '+ ',
                            DiffLineKind.removed => '− ',
                            DiffLineKind.context => '  ',
                          }),
                          Expanded(
                            child: SelectableText(
                              line.text.replaceAll('\r', ''),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                height: 1.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
