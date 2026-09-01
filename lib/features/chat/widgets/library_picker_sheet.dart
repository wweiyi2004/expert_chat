import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/library_models.dart';
import '../../../data/library_repository.dart';
import '../../../data/models.dart';

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
    builder: (ctx) => _LibraryPickerBody(
      repository: repository,
      maxCount: maxCount,
      initialKind: kind,
    ),
  );
}

class _LibraryPickerBody extends StatefulWidget {
  const _LibraryPickerBody({
    required this.repository,
    required this.maxCount,
    this.initialKind,
  });

  final LibraryRepository repository;
  final int maxCount;
  final LibraryItemKind? initialKind;

  @override
  State<_LibraryPickerBody> createState() => _LibraryPickerBodyState();
}

class _LibraryPickerBodyState extends State<_LibraryPickerBody> {
  late LibraryItemKind _kind = widget.initialKind ?? LibraryItemKind.image;
  List<LibraryItem> _items = const [];
  final _selected = <String>{};
  bool _loading = true;
  bool _deleting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.repository.list(kind: _kind);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _selected.removeWhere((id) => items.every((item) => item.id != id));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法读取素材库：$e';
      });
    }
  }

  Future<void> _confirm() async {
    if (_selected.isEmpty) return;
    final out = <Attachment>[];
    for (final item in _items) {
      if (!_selected.contains(item.id)) continue;
      final attachment = await widget.repository.toAttachment(item);
      if (attachment != null) out.add(attachment);
      if (out.length >= widget.maxCount) break;
    }
    if (!mounted) return;
    Navigator.of(context).pop(out);
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
    setState(() => _deleting = true);
    for (final id in _selected.toList()) {
      await widget.repository.delete(id);
    }
    if (!mounted) return;
    _selected.clear();
    setState(() => _deleting = false);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.72;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Text(
                  '素材库',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_selected.isNotEmpty)
                  TextButton(
                    onPressed: _deleting ? null : _deleteSelected,
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
                onSelectionChanged: (next) {
                  setState(() => _kind = next.first);
                  _reload();
                },
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(child: Text(_error!))
                : _items.isEmpty
                ? Center(
                    child: Text(
                      _kind == LibraryItemKind.image
                          ? '还没有图片素材。上传后会自动保存到这里。'
                          : '还没有文件素材。上传后会自动保存到这里。',
                      textAlign: TextAlign.center,
                    ),
                  )
                : _kind == LibraryItemKind.image
                ? _ImageGrid(
                    items: _items,
                    selected: _selected,
                    repository: widget.repository,
                    onToggle: _toggle,
                  )
                : _FileList(
                    items: _items,
                    selected: _selected,
                    onToggle: _toggle,
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Text(
                    '已选 ${_selected.length} / ${widget.maxCount}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _selected.isEmpty ? null : _confirm,
                    child: const Text('选用'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else if (_selected.length < widget.maxCount) {
        _selected.add(id);
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
  });

  final List<LibraryItem> items;
  final Set<String> selected;
  final LibraryRepository repository;
  final ValueChanged<String> onToggle;

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
          onTap: () => onToggle(item.id),
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
                child: Icon(
                  on ? Icons.check_circle : Icons.circle_outlined,
                  color: on
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white,
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
  });

  final List<LibraryItem> items;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final on = selected.contains(item.id);
        final kb = (item.sizeBytes / 1024).toStringAsFixed(0);
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

class _LibraryThumb extends StatefulWidget {
  const _LibraryThumb({required this.repository, required this.item});

  final LibraryRepository repository;
  final LibraryItem item;

  @override
  State<_LibraryThumb> createState() => _LibraryThumbState();
}

class _LibraryThumbState extends State<_LibraryThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await widget.repository.readBytes(widget.item);
    if (!mounted || bytes == null) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(child: Icon(Icons.image_outlined)),
      );
    }
    return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
  }
}
