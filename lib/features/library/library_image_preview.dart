import 'dart:typed_data';
import 'dart:convert';
import '../../data/library_models.dart';
import '../../data/library_repository.dart';
import '../../data/models.dart';
import '../chat/widgets/image_viewer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';

/// Lazy, bounded decoding. A changed item or expected hash always reloads;
/// otherwise filtering/reordering a gallery could display the previous image.
class LibraryImagePreview extends ConsumerStatefulWidget {
  const LibraryImagePreview({
    super.key,
    required this.itemId,
    this.expectedHash,
    this.fit = BoxFit.contain,
    this.height = 220,
    this.cacheWidth = 600,
    this.missingText = '图片不可用',
    this.zoom = false,
    this.repository,
  });
  final String? itemId;
  final String? expectedHash;
  final BoxFit fit;
  final double height;
  final int cacheWidth;
  final String missingText;
  final bool zoom;
  final LibraryRepository? repository;
  @override
  ConsumerState<LibraryImagePreview> createState() =>
      _LibraryImagePreviewState();
}

class _LibraryImagePreviewState extends ConsumerState<LibraryImagePreview> {
  late Future<_PreviewData?> _bytes = _load();
  Future<_PreviewData?> _load() async {
    if (widget.itemId == null) return null;
    final LibraryRepository repository =
        widget.repository ??
        ref.read<LibraryRepository>(libraryRepositoryProvider);
    final item = await repository.getById(widget.itemId!);
    if (item == null ||
        !item.isImage ||
        (widget.expectedHash != null && item.sha256 != widget.expectedHash)) {
      return null;
    }
    final bytes = await repository.readBytes(item);
    return bytes == null ? null : _PreviewData(item, bytes);
  }

  @override
  void didUpdateWidget(LibraryImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId ||
        oldWidget.expectedHash != widget.expectedHash ||
        oldWidget.repository != widget.repository) {
      _bytes = _load();
    }
  }

  void _zoom(_PreviewData data) {
    ImageViewerPage.open(
      context,
      Attachment(
        name: data.item.name,
        mimeType: data.item.mimeType,
        sizeBytes: data.bytes.length,
        imageBase64: base64Encode(data.bytes),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.height,
    width: double.infinity,
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: FutureBuilder<_PreviewData?>(
        future: _bytes,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          if (snapshot.data == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.image_outlined, size: 28),
                    const SizedBox(height: 8),
                    Text(
                      widget.missingText,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          }
          final image = Image.memory(
            snapshot.data!.bytes,
            fit: widget.fit,
            cacheWidth: widget.cacheWidth,
            errorBuilder: (_, _, _) => const Center(child: Text('图片无法预览')),
          );
          return widget.zoom
              ? Semantics(
                  button: true,
                  label: '查看大图',
                  child: InkWell(
                    onTap: () => _zoom(snapshot.data!),
                    child: image,
                  ),
                )
              : image;
        },
      ),
    ),
  );
}

class _PreviewData {
  const _PreviewData(this.item, this.bytes);
  final LibraryItem item;
  final Uint8List bytes;
}
