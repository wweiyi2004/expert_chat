import 'package:expert_chat/core/app_toast.dart';
import 'dart:convert';
import '../../../core/prototype_widgets.dart';
import 'package:crypto/crypto.dart';
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
    if (change.isNew) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('回退新建文件'),
          content: Text('核验版本后删除：${change.path}\n文件内容快照会保留；用户已修改时拒绝删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('核验版本并删除'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    setState(() {
      _restoringId = change.id;
      _error = null;
    });
    try {
      final notifier = ref.read(workChangesProvider.notifier);
      await widget.restore(change);
      await notifier.markReverted(change);
      if (mounted) {
        AppToastMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(change.isNew ? '已核验并删除本轮新建文件；快照保留' : '已恢复修改前的文件内容'),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _restoringId = null);
    }
  }

  Future<void> _recoverCreated(WorkFileChange change) async {
    setState(() => _restoringId = change.id);
    try {
      final request = change.requestNewFileRecreation();
      await widget.restore(request);
      await ref
          .read(workChangesProvider.notifier)
          .record(
            conversationId: change.conversationId,
            assistantId: change.assistantId,
            roundId: 'recovery:${DateTime.now().microsecondsSinceEpoch}',
            target: change.target,
            scope: change.scope,
            path: change.path,
            before: null,
            after: change.after,
            afterHash: sha256.convert(utf8.encode(change.after!)).toString(),
          );
      if (mounted) {
        final latest = ref
            .read(workChangesProvider)
            .where(
              (e) =>
                  e.conversationId == change.conversationId &&
                  e.target == change.target &&
                  e.scope == change.scope &&
                  e.path == change.path,
            )
            .lastOrNull;
        if (latest != null) setState(() => _selectedId = latest.id);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _restoringId = null);
    }
  }

  Future<void> _restoreRound(WorkFileChange selected) async {
    final entries = ref
        .read(workChangesProvider)
        .where(
          (e) =>
              e.conversationId == selected.conversationId &&
              e.assistantId == selected.assistantId &&
              e.roundId == selected.roundId &&
              e.canRestore,
        )
        .toList()
        .reversed
        .toList();
    if (entries.isEmpty) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('回退这一工具轮'),
        content: Text(
          '依次回退 ${entries.length} 个文本改动（其中 ${entries.where((e) => e.isNew).length} 个新建文件将删除）。每个文件先核验当前版本；用户编辑/冲突时立即停止；快照保留。任意命令及外部服务副作用不回滚。\n${entries.map((e) => e.path).join('\n')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('核验版本并回退'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    setState(() => _restoringId = selected.id);
    try {
      for (final change in entries) {
        await widget.restore(change);
        await ref.read(workChangesProvider.notifier).markReverted(change);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '已停止回退，保留剩余文件：$error');
    } finally {
      if (mounted) setState(() => _restoringId = null);
    }
  }

  Future<void> _restoreBlocks(WorkFileChange change, Set<int> selected) async {
    final content = revertDiffBlocks(change.before!, change.after!, selected);
    final request = WorkFileChange(
      id: change.id,
      conversationId: change.conversationId,
      assistantId: change.assistantId,
      target: change.target,
      scope: change.scope,
      path: change.path,
      before: content,
      after: change.after,
      beforeHash: change.beforeHash,
      afterHash: change.afterHash,
      updatedAt: change.updatedAt,
    );
    setState(() => _restoringId = change.id);
    try {
      await widget.restore(request);
      await ref
          .read(workChangesProvider.notifier)
          .record(
            conversationId: change.conversationId,
            assistantId: change.assistantId,
            roundId: 'review:${DateTime.now().microsecondsSinceEpoch}',
            target: change.target,
            scope: change.scope,
            path: change.path,
            before: change.after,
            after: content,
            beforeHash: change.afterHash,
            afterHash: sha256.convert(utf8.encode(content)).toString(),
          );
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
        if (!widget.embedded)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                      compact: widget.embedded,
                      leadingSlivers:
                          widget.embedded && constraints.maxWidth < 840
                          ? [
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  4,
                                  14,
                                  14,
                                ),
                                sliver: SliverList(
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) =>
                                        _fileRow(entries[index], selected),
                                    childCount: entries.length,
                                  ),
                                ),
                              ),
                            ]
                          : const [],
                      onRecoverCreated:
                          _restoringId == null &&
                              selected.reverted &&
                              selected.isNew
                          ? () => _recoverCreated(selected)
                          : null,
                      onRestoreRound:
                          selected.roundId.isNotEmpty && _restoringId == null
                          ? () => _restoreRound(selected)
                          : null,
                      onRestoreBlocks: _restoringId == null
                          ? (blocks) => _restoreBlocks(selected, blocks)
                          : null,
                      restoring: _restoringId == selected.id,
                      onRestore: _restoringId == null && selected.canRestore
                          ? () => _restore(selected)
                          : null,
                    );
                    if (widget.embedded && constraints.maxWidth < 840) {
                      return detail;
                    }
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
        padding: const EdgeInsets.all(14),
        itemCount: entries.length,
        itemBuilder: (context, index) => _fileRow(entries[index], selected),
      );
  Widget _fileRow(WorkFileChange entry, WorkFileChange selected) {
    final c = PrototypeColors.of(context);
    final lines =
        entry.id == selected.id && entry.beforeKnown && entry.textSnapshot
        ? buildLineDiff(entry.before, entry.after!)
        : const <DiffLine>[];
    final added = lines.where((l) => l.kind == DiffLineKind.added).length;
    final removed = lines.where((l) => l.kind == DiffLineKind.removed).length;
    return Material(
      color: entry.id == selected.id ? c.panel : c.surface,
      child: InkWell(
        onTap: () => setState(() {
          _selectedId = entry.id;
          _error = null;
        }),
        child: Container(
          constraints: BoxConstraints(
            minHeight: MediaQuery.sizeOf(context).width < 840 ? 44 : 34,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.line)),
          ),
          child: Row(
            children: [
              Icon(
                entry.reverted
                    ? Icons.undo
                    : entry.isNew
                    ? Icons.note_add_outlined
                    : Icons.insert_drive_file_outlined,
                size: 14,
                color: c.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: '${entry.path} · ${entry.targetLabel}',
                  child: Text(
                    entry.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              if (entry.id == selected.id &&
                  entry.beforeKnown &&
                  entry.textSnapshot) ...[
                const SizedBox(width: 8),
                Text(
                  '+$added',
                  style: TextStyle(fontSize: 12, color: c.success),
                ),
                const SizedBox(width: 8),
                Text(
                  '−$removed',
                  style: TextStyle(fontSize: 12, color: c.confirmation),
                ),
              ],
              if (entry.reverted)
                Text('已撤销', style: TextStyle(fontSize: 11, color: c.faint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangeDetail extends StatefulWidget {
  const _ChangeDetail({
    super.key,
    required this.change,
    required this.restoring,
    required this.onRestore,
    this.onRestoreRound,
    this.onRecoverCreated,
    this.onRestoreBlocks,
    this.compact = false,
    this.leadingSlivers = const [],
  });

  final bool compact;
  final List<Widget> leadingSlivers;
  final WorkFileChange change;
  final bool restoring;
  final VoidCallback? onRestore;
  final VoidCallback? onRestoreRound;
  final VoidCallback? onRecoverCreated;
  final void Function(Set<int>)? onRestoreBlocks;

  @override
  State<_ChangeDetail> createState() => _ChangeDetailState();
}

class _ChangeDetailState extends State<_ChangeDetail> {
  late final List<DiffLine> _lines =
      !widget.change.textSnapshot || widget.change.after == null
      ? const []
      : buildLineDiff(
          widget.change.beforeKnown
              ? widget.change.before
              : widget.change.after!,
          widget.change.after!,
        );
  bool _showUnchanged = false;
  final _selectedBlocks = <int>{};

  Future<void> _reviewBlocks() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, update) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .65,
          child: Column(
            children: [
              const ListTile(title: Text('逐块审阅与选择性回退')),
              Expanded(
                child: ListView(
                  children: [
                    for (final block in changedDiffBlocks(
                      widget.change.before!,
                      widget.change.after!,
                    ).indexed)
                      CheckboxListTile(
                        value: _selectedBlocks.contains(block.$1),
                        title: Text(
                          '改动块 ${block.$1 + 1} · ${block.$2.length} 行',
                        ),
                        subtitle: Text(
                          block.$2
                              .take(4)
                              .map(
                                (line) =>
                                    '${line.kind == DiffLineKind.removed ? '-' : '+'} ${line.text}',
                              )
                              .join('\n'),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onChanged: widget.restoring
                            ? null
                            : (value) => update(() {
                                if (value == true) {
                                  _selectedBlocks.add(block.$1);
                                } else {
                                  _selectedBlocks.remove(block.$1);
                                }
                              }),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: PrototypeButton(
                  label: '回退选中块（版本校验）',
                  variant: PrototypeButtonVariant.danger,
                  onPressed: _selectedBlocks.isEmpty || widget.restoring
                      ? null
                      : () {
                          widget.onRestoreBlocks?.call(Set.of(_selectedBlocks));
                          Navigator.pop(sheet);
                        },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final change = widget.change;
    final c = PrototypeColors.of(context);
    final visible = _showUnchanged || !change.beforeKnown
        ? _lines
        : _lines.where((line) => line.kind != DiffLineKind.context).toList();
    return CustomScrollView(
      key: const ValueKey('work-changes-scroll'),
      slivers: [
        ...widget.leadingSlivers,
        if (!widget.compact)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    change.path,
                    style: const TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                  Text(
                    '${change.targetLabel} · ${change.scope}',
                    style: TextStyle(fontSize: 11.5, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
        if (!change.textSnapshot)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                change.deleted
                    ? '文件已删除。父版本 SHA-256：${change.beforeHash}。删除记录不含完整原始字节，无法安全恢复；请使用项目备份。'
                    : '二进制或大文件已整合。SHA-256：${change.afterHash}\n大小：${change.artifactManifest?["bytes"] ?? "未知"} 字节。没有文本快照，逐行差异与恢复不可用；请从文件工具预览或下载。',
              ),
            ),
          ),
        if (!change.beforeKnown && change.textSnapshot)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text('缺少原始版本，增删行数未统计', style: TextStyle(fontSize: 12)),
            ),
          ),
        if (visible.isEmpty && change.textSnapshot)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('文件内容没有变化', style: TextStyle(fontSize: 13)),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final line = visible[index];
                final color = line.kind == DiffLineKind.added
                    ? c.success
                    : line.kind == DiffLineKind.removed
                    ? c.confirmation
                    : c.muted;
                return Container(
                  decoration: BoxDecoration(
                    color: line.kind == DiffLineKind.context
                        ? c.surface
                        : color.withValues(alpha: .08),
                    border: Border(
                      left: BorderSide(color: c.line),
                      right: BorderSide(color: c.line),
                      top: index == 0
                          ? BorderSide(color: c.line)
                          : BorderSide.none,
                      bottom: index == visible.length - 1
                          ? BorderSide(color: c.line)
                          : BorderSide.none,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${line.oldLine ?? ''}',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.8,
                            color: c.faint,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${line.newLine ?? ''}',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.8,
                            color: c.faint,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        line.kind == DiffLineKind.added
                            ? '+ '
                            : line.kind == DiffLineKind.removed
                            ? '− '
                            : '  ',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.7,
                          color: color,
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          line.text.replaceAll('\r', ''),
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.7,
                            color: color,
                            fontFamily: 'monospace',
                            fontFamilyFallback: const [
                              'NotoSansSC',
                              'Microsoft YaHei',
                              'PingFang SC',
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }, childCount: visible.length),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PrototypeButton(
                  label: change.reverted ? '已撤销' : '撤销该文件改动',
                  small: true,
                  icon: Icons.undo,
                  onPressed: widget.onRestore,
                  tooltip: change.textSnapshot && !change.deleted
                      ? '恢复本记录修改前内容；版本变化时拒绝覆盖'
                      : '未保存完整原始字节，无法安全恢复；请使用项目备份',
                ),
                if (change.canRestore && widget.onRestoreRound != null)
                  PrototypeButton(
                    label: '回退这一工具轮（版本校验）',
                    small: true,
                    onPressed: widget.onRestoreRound,
                  ),
                if (change.canRestore && change.before != null)
                  PrototypeButton(
                    label: '逐块审阅与选择性回退',
                    small: true,
                    onPressed: _reviewBlocks,
                  ),
                if (widget.onRecoverCreated != null)
                  PrototypeButton(
                    label: '从快照重新创建（已有文件时拒绝）',
                    small: true,
                    onPressed: widget.onRecoverCreated,
                  ),
                if (change.beforeKnown && change.textSnapshot)
                  PrototypeChip(
                    label: '显示未改动行',
                    selected: _showUnchanged,
                    onPressed: () =>
                        setState(() => _showUnchanged = !_showUnchanged),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
