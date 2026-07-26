import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/models.dart';

/// base64 payloads at or above this length decode on a background isolate;
/// below it the isolate round-trip costs more than the decode itself.
const int _computeDecodeThreshold = 256 * 1024;

/// Stored conversations can outlive an interrupted write or a schema change,
/// so a malformed payload degrades to null instead of throwing during build.
Uint8List? _tryDecodeBase64(String value) {
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}

/// Compact file card shown in the composer (and on user message bubbles).
/// Surfaces the file name, a status line (size / truncated / parse error) and,
/// when [onRemove] is given, a remove button.
class AttachmentChip extends StatefulWidget {
  const AttachmentChip({super.key, required this.attachment, this.onRemove});

  final Attachment attachment;
  final VoidCallback? onRemove;

  @override
  State<AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends State<AttachmentChip> {
  /// Decoded once and cached: the composer rebuilds this chip on every keystroke
  /// and on streaming-state changes, and re-running base64Decode each frame
  /// wastes CPU and causes the thumbnail to flicker (new bytes → cache miss).
  Uint8List? _imageBytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(AttachmentChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.imageBase64 != widget.attachment.imageBase64) {
      _decode();
    }
  }

  void _decode() {
    final b64 = widget.attachment.imageBase64;
    if (b64 == null) {
      _imageBytes = null;
      return;
    }
    if (b64.length < _computeDecodeThreshold) {
      _imageBytes = _tryDecodeBase64(b64);
      return;
    }
    // Large payload: fall back to the type icon while an isolate decodes.
    _imageBytes = null;
    unawaited(_decodeInBackground(b64));
  }

  Future<void> _decodeInBackground(String value) async {
    final decoded = await compute(_tryDecodeBase64, value);
    if (!mounted || widget.attachment.imageBase64 != value) return;
    setState(() => _imageBytes = decoded);
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    final onRemove = widget.onRemove;
    final scheme = Theme.of(context).colorScheme;
    final hasError = attachment.parseError != null;
    final color = hasError ? scheme.error : scheme.primary;

    return Semantics(
      container: true,
      label: '${attachment.name}，${_status(attachment)}',
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.only(left: 12, top: 7, bottom: 7),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: hasError
                ? scheme.error.withValues(alpha: 0.5)
                : scheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _leading(color),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _status(attachment),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: color),
                  ),
                ],
              ),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: '移除 ${attachment.name}',
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded, size: 18),
                color: scheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  /// A small image thumbnail when the attachment is a retained image, else the
  /// type icon.
  Widget _leading(Color color) {
    final bytes = _imageBytes;
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          bytes,
          width: 28,
          height: 28,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              Icon(_iconFor(widget.attachment), size: 20, color: color),
        ),
      );
    }
    final remoteUrl = widget.attachment.remoteUrl;
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          remoteUrl,
          width: 28,
          height: 28,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              Icon(_iconFor(widget.attachment), size: 20, color: color),
        ),
      );
    }
    return Icon(_iconFor(widget.attachment), size: 20, color: color);
  }

  String _status(Attachment a) {
    if (a.parseError != null) return a.parseError!;
    final kb = (a.sizeBytes / 1024).clamp(0, double.infinity);
    final size = kb >= 1024
        ? '${(kb / 1024).toStringAsFixed(1)} MB'
        : '${kb.toStringAsFixed(0)} KB';
    if (a.truncated) return '$size · 内容已截断';
    return size;
  }

  IconData _iconFor(Attachment a) {
    if (a.isImage) return Icons.image_outlined;
    final n = a.name.toLowerCase();
    if (n.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (n.endsWith('.docx')) return Icons.description_outlined;
    if (n.endsWith('.xlsx')) return Icons.table_chart_outlined;
    if (n.endsWith('.pptx')) return Icons.slideshow_outlined;
    return Icons.insert_drive_file_outlined;
  }
}

/// Full-size image used for generated assistant media.
class AttachmentImage extends StatefulWidget {
  const AttachmentImage({super.key, required this.attachment});

  final Attachment attachment;

  @override
  State<AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<AttachmentImage> {
  Uint8List? _bytes;
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(AttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.imageBase64 != widget.attachment.imageBase64) {
      _decode();
    }
  }

  void _decode() {
    final value = widget.attachment.imageBase64;
    if (value == null || value.isEmpty) {
      _bytes = null;
      _decoding = false;
      return;
    }
    if (value.length < _computeDecodeThreshold) {
      _bytes = _tryDecodeBase64(value);
      _decoding = false;
      return;
    }
    // Generated images reach ~24 MB; a synchronous decode would stall the UI
    // thread for the whole frame. Show progress and decode on an isolate.
    _bytes = null;
    _decoding = true;
    unawaited(_decodeInBackground(value));
  }

  Future<void> _decodeInBackground(String value) async {
    final decoded = await compute(_tryDecodeBase64, value);
    if (!mounted || widget.attachment.imageBase64 != value) return;
    setState(() {
      _bytes = decoded;
      _decoding = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = _bytes;
    final remoteUrl = widget.attachment.remoteUrl;
    Widget image;
    if (bytes != null) {
      image = Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _error(scheme),
      );
    } else if (_decoding) {
      image = Container(
        width: 240,
        height: 140,
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      );
    } else if (remoteUrl != null && remoteUrl.isNotEmpty) {
      image = Image.network(
        remoteUrl,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _error(scheme),
      );
    } else {
      image = _error(scheme);
    }
    return Semantics(
      image: true,
      label: widget.attachment.name,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
          child: image,
        ),
      ),
    );
  }

  Widget _error(ColorScheme scheme) => Container(
    width: 240,
    height: 140,
    color: scheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
        const SizedBox(height: 6),
        Text('图片无法显示', style: TextStyle(color: scheme.onSurfaceVariant)),
      ],
    ),
  );
}
