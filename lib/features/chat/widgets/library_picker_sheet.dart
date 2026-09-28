import 'package:flutter/material.dart';

import '../../../data/library_models.dart';
import '../../../data/library_repository.dart';
import '../../../data/models.dart';
import '../../projects/project_document_page.dart';
import '../../library/library_image_preview.dart';
import '../../shared/recovery_notice.dart';

Future<List<Attachment>?> showLibraryPicker(
  BuildContext context, {
  required LibraryRepository repository,
  required int maxCount,
  LibraryItemKind? kind,
}) {
  return showModalBottomSheet<List<Attachment>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: LibraryBrowser(
        repository: repository,
        maxCount: maxCount,
        initialKind: kind,
      ),
    ),
  );
}

class LibraryBrowser extends StatefulWidget {
  const LibraryBrowser({
    super.key,
    this.manageOnly = false,
    required this.repository,
    required this.maxCount,
    this.initialKind,
  });

  final bool manageOnly;
  final LibraryRepository repository;
  final int maxCount;
  final LibraryItemKind? initialKind;

  @override
  State<LibraryBrowser> createState() => _LibraryBrowserState();
}

class _LibraryBrowserState extends State<LibraryBrowser> {
  late LibraryItemKind _kind = widget.initialKind ?? LibraryItemKind.image;
  List<LibraryItem> _items = const [];
  final _selected = <String>{};
  final _selection = <String, LibraryItem>{};
  final _search = TextEditingController();
  bool _confirming = false;
  bool _loading = true;
  bool _deleting = false;
  int _loadVersion = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final request = ++_loadVersion;
    final kind = _kind;
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
    });
    try {
      final items = await widget.repository.list(kind: kind);
      if (!mounted || request != _loadVersion) return;
      setState(() {
        _items = items;
        _loading = false;
        _selected.removeWhere(
          (id) =>
              _selection[id]?.kind == kind &&
              items.every((item) => item.id != id),
        );
        _selection.removeWhere((id, _) => !_selected.contains(id));
        for (final item in items) {
          if (_selected.contains(item.id)) _selection[item.id] = item;
        }
      });
    } catch (e) {
      if (!mounted || request != _loadVersion) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_selected.isEmpty || _confirming) return;
    setState(() {
      _confirming = true;
      _error = null;
    });
    try {
      final out = <Attachment>[];
      for (final item in _selection.values) {
        final attachment = await widget.repository.toAttachment(item);
        if (attachment == null) {
          throw StateError('素材「${item.name}」已无法读取，请取消选择或重新导入。');
        }
        out.add(attachment);
      }
      if (mounted) Navigator.of(context).pop(out);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('删除素材？'),
        content: Text('将删除选中的 $count 个素材，文件无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      for (final id in _selected.toList()) {
        await widget.repository.delete(id);
        _selected.remove(id);
        _selection.remove(id);
      }
      if (mounted) await _reload();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height =
        (MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom) *
        0.82;
    final visible = _items
        .where(
          (item) => item.name.toLowerCase().contains(
            _search.text.trim().toLowerCase(),
          ),
        )
        .toList();
    return SizedBox(
      height: widget.manageOnly ? double.infinity : height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Text(
                  widget.manageOnly ? '预览与管理' : '素材库',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (widget.manageOnly && _selected.isNotEmpty)
                  TextButton(
                    onPressed: _deleting || _confirming
                        ? null
                        : _deleteSelected,
                    child: Text('删除 ${_selected.length}'),
                  ),
              ],
            ),
          ),
          if (widget.initialKind == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SegmentedButton<LibraryItemKind>(
                segments: const [
                  ButtonSegment(
                    value: LibraryItemKind.image,
                    label: Text('图片'),
                    icon: Icon(Icons.image_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: LibraryItemKind.file,
                    label: Text('文件'),
                    icon: Icon(Icons.insert_drive_file_outlined, size: 16),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: _deleting || _confirming
                    ? null
                    : (next) {
                        setState(() => _kind = next.first);
                        _reload();
                      },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: TextField(
              key: const ValueKey('library-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索素材名称',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除素材搜索',
                        onPressed: () => setState(_search.clear),
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  if (_error != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            constraints.maxHeight * (_items.isEmpty ? 1 : 0.6),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: RecoveryNotice(
                          error: _error!,
                          title: '素材操作未完成',
                          onRetry: _reload,
                          retryLabel: '重新加载素材',
                        ),
                      ),
                    ),
                  if (_error == null || _items.isNotEmpty)
                    Expanded(
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : visible.isEmpty
                          ? Center(
                              child: Text(
                                _error != null
                                    ? '请重新加载素材列表。'
                                    : _search.text.isNotEmpty
                                    ? '没有匹配的素材，试试其他关键词。'
                                    : _kind == LibraryItemKind.image
                                    ? '还没有图片素材。上传后会自动保存到这里。'
                                    : '还没有文件素材。上传后会自动保存到这里。',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : _kind == LibraryItemKind.image
                          ? _ImageGrid(
                              items: visible,
                              selected: _selected,
                              repository: widget.repository,
                              onToggle: _toggle,
                              onPreview: widget.manageOnly ? _preview : null,
                            )
                          : _FileList(
                              items: visible,
                              selected: _selected,
                              onToggle: _toggle,
                              onPreview: widget.manageOnly ? _preview : null,
                            ),
                    ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Text(
                    widget.manageOnly
                        ? '已选 ${_selected.length} 项'
                        : '已选 ${_selected.length} / ${widget.maxCount}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (widget.manageOnly)
                    TextButton(
                      onPressed: _selected.isEmpty || _deleting
                          ? null
                          : () => setState(() {
                              _selected.clear();
                              _selection.clear();
                            }),
                      child: const Text('取消选择'),
                    )
                  else
                    FilledButton(
                      onPressed: _selected.isEmpty || _confirming || _deleting
                          ? null
                          : _confirm,
                      child: Text(_confirming ? '正在读取…' : '选用'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _preview(LibraryItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => item.kind == LibraryItemKind.file
            ? ProjectDocumentPage(item: item)
            : Scaffold(
                appBar: AppBar(
                  title: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                body: LayoutBuilder(
                  builder: (context, constraints) => InteractiveViewer(
                    child: LibraryImagePreview(
                      itemId: item.id,
                      expectedHash: item.sha256,
                      repository: widget.repository,
                      fit: BoxFit.contain,
                      height: constraints.maxHeight,
                      cacheWidth: 1200,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  void _toggle(String id) {
    if (_confirming || _deleting) return;
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
        _selection.remove(id);
      } else if (widget.manageOnly || _selected.length < widget.maxCount) {
        _selected.add(id);
        _selection[id] = _items.firstWhere((item) => item.id == id);
      }
    });
  }
}

class _ImageGrid extends StatelessWidget {
  const _ImageGrid({
    required this.items,
    required this.selected,
    required this.repository,
    required this.onToggle,
    this.onPreview,
  });

  final List<LibraryItem> items;
  final Set<String> selected;
  final LibraryRepository repository;
  final ValueChanged<String> onToggle;
  final ValueChanged<LibraryItem>? onPreview;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final on = selected.contains(item.id);
        return InkWell(
          onTap: () => onPreview == null ? onToggle(item.id) : onPreview!(item),
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _LibraryThumb(repository: repository, item: item),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: IconButton(
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  tooltip: on ? '取消选择 ${item.name}' : '选择 ${item.name}',
                  onPressed: () => onToggle(item.id),
                  icon: Icon(
                    on ? Icons.check_circle : Icons.circle_outlined,
                    color: on
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white,
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 4),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({
    required this.items,
    required this.selected,
    required this.onToggle,
    this.onPreview,
  });

  final List<LibraryItem> items;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final ValueChanged<LibraryItem>? onPreview;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final on = selected.contains(item.id);
        final kb = (item.sizeBytes / 1024).toStringAsFixed(0);
        if (onPreview != null) {
          return ListTile(
            leading: Checkbox(value: on, onChanged: (_) => onToggle(item.id)),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('$kb KB'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onPreview!(item),
          );
        }
        return CheckboxListTile(
          value: on,
          onChanged: (_) => onToggle(item.id),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('$kb KB'),
        );
      },
    );
  }
}

class _LibraryThumb extends StatelessWidget {
  const _LibraryThumb({required this.repository, required this.item});
  final LibraryRepository repository;
  final LibraryItem item;
  @override
  Widget build(BuildContext context) => LibraryImagePreview(
    itemId: item.id,
    expectedHash: item.sha256,
    repository: repository,
    height: 100,
    fit: BoxFit.cover,
    cacheWidth: 320,
  );
}
