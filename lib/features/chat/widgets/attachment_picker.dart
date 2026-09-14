import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../data/library_models.dart';
import '../../../data/library_repository.dart';
import '../../../domain/tools/attachment_ingestor.dart';
import '../../library/library_image_preview.dart';
import '../../projects/project_document_page.dart';
import 'recent_photo_sheet.dart';

enum AttachmentPickerTab {
  recent('最近使用', Icons.history),
  images('图片', Icons.image_outlined),
  documents('文档', Icons.description_outlined),
  library('素材库', Icons.folder_copy_outlined);

  const AttachmentPickerTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

class AttachmentPickerResult {
  const AttachmentPickerResult(this.sources, {this.confirmImages = false});
  final List<FileIngestSource> sources;
  final bool confirmImages;
}

Future<AttachmentPickerResult?> showAttachmentPicker(
  BuildContext context, {
  required LibraryRepository repository,
  required int maxCount,
  required bool allowImages,
  required bool allowDocuments,
  required bool Function() isCurrent,
  AttachmentPickerTab initialTab = AttachmentPickerTab.recent,
}) {
  final size = MediaQuery.sizeOf(context);
  final panel = AttachmentPicker(
    repository: repository,
    maxCount: maxCount,
    allowImages: allowImages,
    allowDocuments: allowDocuments,
    isCurrent: isCurrent,
    initialTab: initialTab,
  );
  if (size.width >= 700) {
    return showDialog<AttachmentPickerResult>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 820,
          height: (size.height * 0.82).clamp(0, 720),
          child: panel,
        ),
      ),
    );
  }
  return showModalBottomSheet<AttachmentPickerResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height:
            (MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom) *
            0.9,
        child: panel,
      ),
    ),
  );
}

/// Chooses library assets or local files; parsing and import stay with the caller.
class AttachmentPicker extends StatefulWidget {
  const AttachmentPicker({
    super.key,
    required this.repository,
    required this.maxCount,
    required this.allowImages,
    required this.allowDocuments,
    required this.isCurrent,
    this.initialTab = AttachmentPickerTab.recent,
  });

  final LibraryRepository repository;
  final int maxCount;
  final bool allowImages;
  final bool allowDocuments;
  final bool Function() isCurrent;
  final AttachmentPickerTab initialTab;

  @override
  State<AttachmentPicker> createState() => _AttachmentPickerState();
}

class _AttachmentPickerState extends State<AttachmentPicker> {
  late AttachmentPickerTab _tab = widget.initialTab;
  final _search = TextEditingController();
  final _selected = <String, LibraryItem>{};
  List<LibraryItem> _items = const [];
  bool _loading = true;
  bool _browsing = false;
  String? _error;
  String? _loadError;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    if (!_enabled(_tab)) _tab = AttachmentPickerTab.recent;
    _reload();
  }

  bool _enabled(AttachmentPickerTab tab) => switch (tab) {
    AttachmentPickerTab.images => widget.allowImages,
    AttachmentPickerTab.documents => widget.allowDocuments,
    _ => true,
  };

  bool _accepts(LibraryItem item) => item.isImage
      ? widget.allowImages &&
            AttachmentIngestor.imageExtensions.contains(_itemExtension(item))
      : widget.allowDocuments &&
            AttachmentIngestor.documentExtensions.contains(
              _extension(item.name),
            );

  Future<void> _reload() async {
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _error = null;
      _loadError = null;
    });
    try {
      final items = await widget.repository.list();
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _items = items.where(_accepts).toList()
          ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
        _selected.removeWhere((id, _) => !_items.any((item) => item.id == id));
        for (final item in _items) {
          if (_selected.containsKey(item.id)) _selected[item.id] = item;
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loading = false;
        _loadError = '素材加载失败，请重试。你也可以浏览本机文件。';
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(LibraryItem item) {
    if (_browsing) return;
    setState(() {
      if (_selected.containsKey(item.id)) {
        _selected.remove(item.id);
      } else if (_selected.length < widget.maxCount) {
        _selected[item.id] = item;
      }
    });
  }

  void _finish({
    List<FileIngestSource> extra = const [],
    bool confirmImages = false,
  }) {
    if (!mounted) return;
    if (!widget.isCurrent()) {
      Navigator.of(context).pop();
      return;
    }
    final sources = [
      for (final item in _selected.values)
        FileIngestSource(
          name: item.name,
          extension: _itemExtension(item),
          reportedSize: item.sizeBytes,
          loadBytes: () => widget.repository.readBytes(item),
        ),
      ...extra,
    ];
    Navigator.of(
      context,
    ).pop(AttachmentPickerResult(sources, confirmImages: confirmImages));
  }

  Future<void> _browse({bool album = false}) async {
    if (_browsing || _selected.length >= widget.maxCount) return;
    if (!widget.isCurrent()) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _browsing = true;
      _error = null;
    });
    try {
      final remaining = widget.maxCount - _selected.length;
      if (album) {
        final picked = await showRecentPhotoPicker(
          context,
          maxCount: remaining,
        );
        if (!mounted) return;
        if (!widget.isCurrent()) {
          Navigator.of(context).pop();
          return;
        }
        if (picked == null) return;
        if (!picked.fromFiles) {
          _finish(
            extra: [
              for (final asset in picked.assets)
                FileIngestSource(
                  name: (asset.title?.trim().isNotEmpty ?? false)
                      ? asset.title!
                      : 'photo_${asset.id.hashCode}.jpg',
                  extension: 'jpg',
                  loadBytes: () => loadAssetImageBytes(asset),
                ),
            ],
            confirmImages: true,
          );
          return;
        }
      }
      final imagesOnly =
          album || _tab == AttachmentPickerTab.images || !widget.allowDocuments;
      final documentsOnly = _tab == AttachmentPickerTab.documents;
      final extensions = [
        if (!imagesOnly && widget.allowDocuments)
          ...AttachmentIngestor.documentExtensions,
        if ((!documentsOnly && widget.allowImages) || album)
          ...AttachmentIngestor.imageExtensions,
      ];
      final picked = await FilePicker.pickFiles(
        dialogTitle: imagesOnly
            ? '选择图片'
            : documentsOnly
            ? '选择文档'
            : '选择文件',
        type: FileType.custom,
        allowedExtensions: extensions,
        allowMultiple: remaining > 1,
        withData: false,
        withReadStream: true,
      );
      if (!mounted) return;
      if (!widget.isCurrent()) {
        Navigator.of(context).pop();
        return;
      }
      if (picked == null || picked.files.isEmpty) return;
      if (picked.files.any(
        (file) => !extensions.contains(file.extension?.toLowerCase()),
      )) {
        setState(() => _error = '所选文件包含当前分类不支持的格式，请重新选择。');
        return;
      }
      _finish(
        extra: [
          for (final file in picked.files)
            FileIngestSource(
              name: file.name,
              extension: file.extension?.toLowerCase(),
              path: file.path,
              bytes: file.bytes,
              reportedSize: file.size,
              stream: file.readStream,
            ),
        ],
        confirmImages: true,
      );
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开文件选择器，请重试。');
    } finally {
      if (mounted) setState(() => _browsing = false);
    }
  }

  void _preview(LibraryItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => item.isImage
            ? Scaffold(
                appBar: AppBar(title: Text(item.name)),
                body: Center(
                  child: LibraryImagePreview(
                    itemId: item.id,
                    expectedHash: item.sha256,
                    repository: widget.repository,
                    height: MediaQuery.sizeOf(context).height * 0.75,
                    cacheWidth: 1200,
                    zoom: true,
                  ),
                ),
              )
            : ProjectDocumentPage(item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = _error ?? _loadError;
    final query = _search.text.trim().toLowerCase();
    var items = _items
        .where(
          (item) => switch (_tab) {
            AttachmentPickerTab.images => item.isImage,
            AttachmentPickerTab.documents => !item.isImage,
            _ => true,
          },
        )
        .toList();
    if (_tab == AttachmentPickerTab.recent) items = items.take(24).toList();
    if (_tab == AttachmentPickerTab.library) {
      items.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    }
    items = items
        .where((item) => item.name.toLowerCase().contains(query))
        .toList();
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.attach_file),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '添加附件',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('attachment-picker-close'),
                    tooltip: '关闭文件选择',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    for (final tab in AttachmentPickerTab.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: ValueKey('attachment-tab-${tab.name}'),
                          avatar: Icon(tab.icon, size: 17),
                          label: Text(tab.label),
                          selected: _tab == tab,
                          showCheckmark: false,
                          onSelected: !_enabled(tab) || _browsing
                              ? null
                              : (_) => setState(() => _tab = tab),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                key: const ValueKey('attachment-picker-search'),
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '搜索文件名称',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除文件搜索',
                          onPressed: () => setState(_search.clear),
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : error != null
                  ? SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Text(error, textAlign: TextAlign.center),
                            TextButton(
                              onPressed: _browsing ? null : _reload,
                              child: const Text('重新加载'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : items.isEmpty
                  ? const Center(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            '这里还没有可选文件\n可切换分类、调整搜索，或浏览本机文件。',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  : _tab == AttachmentPickerTab.images
                  ? GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.85,
                          ),
                      itemCount: items.length,
                      itemBuilder: (_, index) => _imageTile(items[index]),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: items.length,
                      itemBuilder: (_, index) => _fileTile(items[index]),
                    ),
            ),
            const Divider(height: 1),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _footer() => LayoutBuilder(
    builder: (context, constraints) {
      final browse = OutlinedButton.icon(
        key: const ValueKey('attachment-browse-local'),
        onPressed: _browsing || _selected.length >= widget.maxCount
            ? null
            : _browse,
        icon: const Icon(Icons.folder_open, size: 18),
        label: Text(_browsing ? '正在选择…' : '浏览本机文件'),
      );
      final album = widget.allowImages && supportsRecentPhotoSheet
          ? TextButton.icon(
              onPressed: _browsing || _selected.length >= widget.maxCount
                  ? null
                  : () => _browse(album: true),
              icon: const Icon(Icons.photo_library_outlined, size: 18),
              label: const Text('手机相册'),
            )
          : null;
      final count = Text(
        '已选 ${_selected.length} / ${widget.maxCount}',
        style: Theme.of(context).textTheme.labelMedium,
      );
      final clear = _selected.isEmpty
          ? null
          : TextButton(
              onPressed: _browsing ? null : () => setState(_selected.clear),
              child: const Text('清空'),
            );
      final confirm = FilledButton(
        key: const ValueKey('attachment-picker-confirm'),
        onPressed: _selected.isEmpty || _browsing ? null : _finish,
        child: const Text('添加'),
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: constraints.maxWidth >= 650
            ? Row(
                children: [
                  browse,
                  if (album != null) ...[const SizedBox(width: 8), album],
                  const Spacer(),
                  count,
                  const SizedBox(width: 12),
                  ?clear,
                  confirm,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(spacing: 8, children: [browse, ?album]),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(child: count),
                      ?clear,
                      confirm,
                    ],
                  ),
                ],
              ),
      );
    },
  );

  Widget _fileTile(LibraryItem item) => ListTile(
    key: ValueKey('attachment-item-${item.id}'),
    leading: item.isImage
        ? SizedBox(
            width: 42,
            height: 42,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LibraryImagePreview(
                itemId: item.id,
                expectedHash: item.sha256,
                repository: widget.repository,
                height: 42,
                cacheWidth: 100,
                fit: BoxFit.cover,
              ),
            ),
          )
        : const Icon(Icons.description_outlined),
    title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text('${(item.sizeBytes / 1024).toStringAsFixed(0)} KB'),
    selected: _selected.containsKey(item.id),
    onTap: _browsing ? null : () => _toggle(item),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '预览 ${item.name}',
          onPressed: _browsing ? null : () => _preview(item),
          icon: const Icon(Icons.visibility_outlined, size: 20),
        ),
        Checkbox(
          value: _selected.containsKey(item.id),
          onChanged: _browsing ? null : (_) => _toggle(item),
        ),
      ],
    ),
  );

  Widget _imageTile(LibraryItem item) => Card(
    key: ValueKey('attachment-item-${item.id}'),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: _browsing ? null : () => _toggle(item),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                LibraryImagePreview(
                  itemId: item.id,
                  expectedHash: item.sha256,
                  repository: widget.repository,
                  fit: BoxFit.cover,
                  cacheWidth: 320,
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: Material(
                    color: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(12),
                    child: Checkbox(
                      value: _selected.containsKey(item.id),
                      onChanged: _browsing ? null : (_) => _toggle(item),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '预览 ${item.name}',
                  onPressed: _browsing ? null : () => _preview(item),
                  icon: const Icon(Icons.zoom_in, size: 20),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String _extension(String name) =>
    name.contains('.') ? name.split('.').last.toLowerCase() : '';

String _itemExtension(LibraryItem item) => item.isImage
    ? switch (item.mimeType.toLowerCase()) {
        'image/jpeg' || 'image/jpg' => 'jpg',
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        'image/bmp' => 'bmp',
        _ => _extension(item.name),
      }
    : _extension(item.name);
