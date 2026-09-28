import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../data/db/app_database.dart' show GenerationRecord;
import '../../domain/media/generation_catalog.dart';
import '../../state/chat_controller.dart';
import '../shell/shell_tab.dart';
import '../shared/recovery_notice.dart';
import 'library_image_preview.dart';

class GenerationHistoryPage extends ConsumerStatefulWidget {
  const GenerationHistoryPage({super.key});
  @override
  ConsumerState<GenerationHistoryPage> createState() =>
      _GenerationHistoryPageState();
}

class _GenerationHistoryPageState extends ConsumerState<GenerationHistoryPage> {
  late Future<List<GenerationRecord>> _records;
  final _selected = <String>{};
  final _search = TextEditingController();
  String? _family;
  int _refresh = 0;
  @override
  void initState() {
    super.initState();
    _records = ref.read(generationRepositoryProvider).list();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _records = ref.read(generationRepositoryProvider).list();
      _selected.clear();
      _refresh++;
    });
    await _records;
  }

  void _toggle(GenerationRecord record) => setState(() {
    if (!_selected.remove(record.id) && _selected.length < 2) {
      _selected.add(record.id);
    }
  });
  void _open(List<GenerationRecord> records, GenerationCatalog catalog) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _GenerationComparison(
          records: records,
          versionLabels: catalog.labels,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('生图版本记录'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: () async {
            try {
              await _reload();
            } catch (_) {
              /* FutureBuilder shows the error. */
            }
          },
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<List<GenerationRecord>>(
      future: _records,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: RecoveryNotice(
                error: snapshot.error!,
                title: '生图记录暂时无法加载',
                onRetry: _reload,
                retryLabel: '重新加载记录',
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final catalog = GenerationCatalog(snapshot.data!);
        final visible = catalog.filter(query: _search.text, family: _family);
        final selected = [
          for (final id in _selected)
            if (catalog.byId[id] != null) catalog.byId[id]!,
        ];
        final scheme = Theme.of(context).colorScheme;
        return SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '找到图片，继续创作',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    const Text('点击图片查看参数，选择两张图片进行对比。'),
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('generation-search'),
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: '搜索描述或模型',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                onPressed: () => setState(_search.clear),
                                icon: const Icon(Icons.close),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          _family == null
                              ? '${visible.length} 条记录 · ${catalog.series.length} 个系列'
                              : '当前系列 · ${visible.length} 个版本',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (_family != null)
                          TextButton(
                            onPressed: () => setState(() => _family = null),
                            child: const Text('查看全部系列'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.image_outlined, size: 44),
                              const SizedBox(height: 12),
                              Text(
                                catalog.records.isEmpty ? '暂无生图记录' : '没有匹配的记录',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                catalog.records.isEmpty
                                    ? '生成的图片和参数会保存在这里，方便再次使用。'
                                    : '试试其他关键词，或清除筛选。',
                                textAlign: TextAlign.center,
                              ),
                              if (catalog.records.isNotEmpty)
                                TextButton(
                                  onPressed: () => setState(() {
                                    _search.clear();
                                    _family = null;
                                  }),
                                  child: const Text('清除筛选'),
                                ),
                            ],
                          ),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final scale =
                              MediaQuery.textScalerOf(context).scale(14) / 14;
                          final columns = scale > 1.4
                              ? 1
                              : constraints.maxWidth >= 1000
                              ? 4
                              : constraints.maxWidth >= 680
                              ? 3
                              : 2;
                          final width =
                              (constraints.maxWidth - 32 - (columns - 1) * 12) /
                              columns;
                          return GridView.builder(
                            key: const ValueKey('generation-grid'),
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  mainAxisExtent: width * 0.78 + 154 * scale,
                                ),
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final record = visible[index];
                              final checked = _selected.contains(record.id);
                              return Card(
                                key: ValueKey('${record.id}-$_refresh'),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  side: BorderSide(
                                    color: checked
                                        ? scheme.primary
                                        : scheme.outlineVariant,
                                    width: checked ? 2 : 1,
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    InkWell(
                                      key: ValueKey(
                                        'generation-open-${record.id}',
                                      ),
                                      onTap: () => _open([record], catalog),
                                      child: LibraryImagePreview(
                                        itemId: record.libraryItemId,
                                        height: width * 0.78,
                                        fit: BoxFit.cover,
                                        cacheWidth: (width * 2).round().clamp(
                                          240,
                                          800,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          12,
                                          10,
                                          12,
                                          0,
                                        ),
                                        child: InkWell(
                                          onTap: () => _open([record], catalog),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                record.originalPrompt,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleSmall,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                record.model,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodySmall,
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                catalog.relationship(record),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        Checkbox(
                                          key: ValueKey(
                                            'generation-select-${record.id}',
                                          ),
                                          value: checked,
                                          onChanged:
                                              !checked && _selected.length >= 2
                                              ? null
                                              : (_) => _toggle(record),
                                        ),
                                        Expanded(
                                          child: Text(
                                            catalog.labels[record.id]!,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        ),
                                        IconButton(
                                          key: ValueKey(
                                            'generation-family-${record.id}',
                                          ),
                                          tooltip: '查看同系列',
                                          onPressed: () => setState(
                                            () => _family = catalog.seriesId(
                                              record.id,
                                            ),
                                          ),
                                          icon: const Icon(
                                            Icons.account_tree_outlined,
                                            size: 18,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
              Material(
                color: scheme.surfaceContainer,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (selected.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            selected
                                .asMap()
                                .entries
                                .map(
                                  (e) =>
                                      '${e.key == 0 ? 'A' : 'B'}：${e.value.originalPrompt}',
                                )
                                .join('   /   '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('已选 ${selected.length} / 2'),
                          if (selected.isNotEmpty)
                            TextButton(
                              onPressed: () => setState(_selected.clear),
                              child: const Text('清空选择'),
                            ),
                          FilledButton(
                            onPressed: selected.length != 2
                                ? null
                                : () => _open(selected, catalog),
                            child: const Text('对比选中的两个版本'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _GenerationComparison extends ConsumerStatefulWidget {
  const _GenerationComparison({
    required this.records,
    required this.versionLabels,
  });
  final List<GenerationRecord> records;
  final Map<String, String> versionLabels;
  @override
  ConsumerState<_GenerationComparison> createState() =>
      _GenerationComparisonState();
}

class _GenerationComparisonState extends ConsumerState<_GenerationComparison> {
  bool _busy = false;
  bool _onlyChanges = false;
  Set<String> get _changes => widget.records.length == 2
      ? GenerationCatalog.changedFields(widget.records[0], widget.records[1])
      : const {};
  Object? _error;
  Future<void> _replay(GenerationRecord record) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认再次生成图片？'),
        content: Text(
          '将在当前会话中按原提示词、参考图和参数重新生成，可能产生费用。\n'
          '模型：${record.model}\n尺寸：${record.imageSize}\n服务：${record.providerHost}\n'
          '新图不会覆盖旧图，结果可能与原图不同。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认生成新版本'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await ref
          .read(chatControllerProvider.notifier)
          .regenerateImageVersion(record);
      if (!mounted) return;
      if (!done) {
        setState(() => _error = '未开始生成，请检查 API 配置或等待当前任务结束。');
      } else {
        openShellTab(ref, ShellTab.chat);
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _parameter(String field, String caption, String value) {
    if (_onlyChanges && !_changes.contains(field)) {
      return const SizedBox.shrink();
    }
    final changed = _changes.contains(field);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: EdgeInsets.all(changed ? 12 : 0),
      decoration: changed
          ? BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            changed ? '$caption · 有变化' : caption,
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          SelectableText(value.isEmpty ? '未提供' : value),
        ],
      ),
    );
  }

  Widget _record(GenerationRecord r) => Card(
    margin: const EdgeInsets.all(4),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.versionLabels[r.id] ?? '生成记录',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (r.parentGenerationId != null)
            Text(
              '基于 ${widget.versionLabels[r.parentGenerationId] ?? '已有版本（记录不可用）'} 生成',
            ),
          const SizedBox(height: 12),
          if (widget.records.length == 1) _RecordImage(record: r),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: r.optimizedPrompt)),
                icon: const Icon(Icons.copy_outlined),
                label: const Text('复制提示词'),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _replay(r),
                child: const Text('按原参数生成新版本'),
              ),
            ],
          ),
          _parameter('模型', '模型', r.model),
          _parameter('尺寸', '尺寸', r.imageSize),
          _parameter('服务', '服务', r.providerHost),
          if (!_onlyChanges)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '时间：${r.createdAt.toLocal()}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          _parameter('原始描述', '你的描述', r.originalPrompt),
          if (r.optimizedPrompt != r.originalPrompt ||
              _changes.contains('实际提示词'))
            _parameter('实际提示词', '生成提示词', r.optimizedPrompt),
          if ((r.revisedPrompt?.isNotEmpty == true &&
                  r.revisedPrompt != r.optimizedPrompt) ||
              _changes.contains('API 修订描述'))
            _parameter('API 修订描述', '服务调整后的提示词', r.revisedPrompt ?? ''),
          if (!_onlyChanges || _changes.contains('参考图')) ...[
            const SizedBox(height: 12),
            _ReferenceImages(referencesJson: r.referencesJson),
          ],
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('技术详情'),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText('记录编号：${r.id}'),
              if (r.parentGenerationId != null)
                SelectableText('来源记录编号：${r.parentGenerationId}'),
              const Text('参考图原始记录'),
              SelectableText(r.referencesJson),
            ],
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.records.length == 1 ? '生图参数' : '版本对比')),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          RecoveryNotice(
            error: _error!,
            guidance: '先查看当前会话中的结果，再决定是否重新生成。再次提交可能产生费用。',
          ),
        if (widget.records.length == 2) ...[
          LayoutBuilder(
            builder: (context, constraints) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < 2; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i == 0 ? '对比 A' : '对比 B',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: LibraryImagePreview(
                              itemId: widget.records[i].libraryItemId,
                              height: constraints.maxWidth < 600 ? 170 : 320,
                              zoom: true,
                              cacheWidth: 1000,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _changes.isEmpty
                        ? '两版记录的生成参数一致'
                        : '变化参数：${_changes.join('、')}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  const Text('参数相同也可能生成不同图片；点击图片可放大查看。'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅显示变化参数'),
                    value: _onlyChanges,
                    onChanged: (v) => setState(() => _onlyChanges = v),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        LayoutBuilder(
          builder: (context, constraints) =>
              constraints.maxWidth >= 800 && widget.records.length == 2
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in widget.records) Expanded(child: _record(r)),
                  ],
                )
              : Column(children: [for (final r in widget.records) _record(r)]),
        ),
      ],
    ),
  );
}

class _ReferenceImages extends StatelessWidget {
  const _ReferenceImages({required this.referencesJson});
  final String referencesJson;

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> rows;
    try {
      rows = List<Map<String, dynamic>>.from(
        jsonDecode(referencesJson) as List,
      );
    } catch (_) {
      return const Text('参考图记录无法读取');
    }
    if (rows.isEmpty) return const Text('未使用参考图');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('参考图（${rows.length}）'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (var i = 0; i < rows.length; i++)
              SizedBox(
                width: 140,
                child: Column(
                  children: [
                    _ReferenceThumbnail(
                      key: ValueKey(
                        '$i-${rows[i]['libraryItemId']}-${rows[i]['sha256']}',
                      ),
                      libraryItemId: rows[i]['libraryItemId'] is String
                          ? rows[i]['libraryItemId'] as String
                          : null,
                      expectedHash: rows[i]['sha256'] is String
                          ? rows[i]['sha256'] as String
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      rows[i]['name'] is String &&
                              (rows[i]['name'] as String).trim().isNotEmpty
                          ? rows[i]['name'] as String
                          : '参考图 ${i + 1}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _ReferenceThumbnail extends StatelessWidget {
  const _ReferenceThumbnail({
    super.key,
    required this.libraryItemId,
    required this.expectedHash,
  });
  final String? libraryItemId;
  final String? expectedHash;
  @override
  Widget build(BuildContext context) => LibraryImagePreview(
    itemId: libraryItemId,
    expectedHash: expectedHash,
    height: 100,
    cacheWidth: 280,
    missingText: '参考图不可用',
  );
}

class _RecordImage extends StatelessWidget {
  const _RecordImage({required this.record});
  final GenerationRecord record;
  @override
  Widget build(BuildContext context) => LibraryImagePreview(
    itemId: record.libraryItemId,
    height: 280,
    cacheWidth: 1000,
    zoom: true,
    missingText: '图片未在本地保存或已删除；参数记录仍保留',
  );
}
