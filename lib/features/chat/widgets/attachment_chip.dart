import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/models.dart';
import 'image_viewer_page.dart';

/// base64 payloads at or above this length decode on a background isolate;
/// below it the isolate round-trip costs more than the decode itself.
const int _computeDecodeThreshold = 256 * 1024;

/// Stored conversations can outlive an interrupted write or a schema change,
/// so a malformed payload degrades to null instead of throwing during build.
Uint8List? _tryDecodeBase64(String value) {
  try {
    var payload = value.trim();
    if (payload.startsWith('data:')) {
      final comma = payload.indexOf(',');
      if (comma > 0) payload = payload.substring(comma + 1);
    }
    if (payload.contains(RegExp(r'\s'))) {
      payload = payload.replaceAll(RegExp(r'\s'), '');
    }
    // URL-safe base64 → standard (some image APIs return this).
    if (payload.contains('-') || payload.contains('_')) {
      payload = payload.replaceAll('-', '+').replaceAll('_', '/');
    }
    if (payload.isNotEmpty && payload.length % 4 != 0) {
      payload = payload.padRight(
        payload.length + (4 - payload.length % 4) % 4,
        '=',
      );
    }
    return base64Decode(payload);
  } on FormatException {
    return null;
  }
}

/// Compact file card shown in the composer (and on user message bubbles).
/// Surfaces the file name, a status line (size / truncated / parse error) and,
/// when [onRemove] is given, a remove button. [onDownload] shows a save action
/// for assistant-returned binary files (e.g. edited xlsx).
class AttachmentChip extends StatefulWidget {
  const AttachmentChip({
    super.key,
    required this.attachment,
    this.onRemove,
    this.onDownload,
  });

  final Attachment attachment;
  final VoidCallback? onRemove;
  final VoidCallback? onDownload;

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
    // Office round-trip files also use [imageBase64]; only decode real images.
    if (!widget.attachment.isImage) {
      _imageBytes = null;
      return;
    }
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
            if (widget.onDownload != null && attachment.hasDownloadableBytes)
              IconButton(
                tooltip: '下载 ${attachment.name}',
                onPressed: widget.onDownload,
                icon: const Icon(Icons.download_rounded, size: 18),
                color: scheme.primary,
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

  /// A small image thumbnail when the attachment is a retained image, else a
  /// format-colored type badge (Word blue / Excel green / …).
  Widget _leading(Color fallbackColor) {
    final bytes = _imageBytes;
    // Decode only thumbnail resolution — full photo decode here OOMs chat lists.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cachePx = (28 * dpr).round().clamp(28, 96);
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          bytes,
          width: 32,
          height: 32,
          cacheWidth: cachePx,
          cacheHeight: cachePx,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, _, _) => _typeBadge(fallbackColor),
        ),
      );
    }
    final remoteUrl = widget.attachment.remoteUrl;
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          remoteUrl,
          width: 32,
          height: 32,
          cacheWidth: cachePx,
          cacheHeight: cachePx,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, _, _) => _typeBadge(fallbackColor),
        ),
      );
    }
    return _typeBadge(fallbackColor);
  }

  Widget _typeBadge(Color fallbackColor) {
    final style = _FileTypeStyle.of(widget.attachment);
    final accent = widget.attachment.parseError != null
        ? fallbackColor
        : style.color;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(style.icon, size: 15, color: accent),
          Text(
            style.label,
            style: TextStyle(
              fontSize: 7.5,
              height: 1.0,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }

  String _status(Attachment a) {
    if (a.parseError != null) return a.parseError!;
    final kb = (a.sizeBytes / 1024).clamp(0, double.infinity);
    final size = kb >= 1024
        ? '${(kb / 1024).toStringAsFixed(1)} MB'
        : '${kb.toStringAsFixed(0)} KB';
    if (!a.isImage && a.hasDownloadableBytes) {
      return '$size · 可下载';
    }
    if (a.truncated) return '$size · 内容已截断';
    return size;
  }
}

/// Visual identity for non-image attachments (icon + short label + brand color).
class _FileTypeStyle {
  const _FileTypeStyle({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  static const _word = _FileTypeStyle(
    icon: Icons.description_rounded,
    label: 'DOC',
    color: Color(0xFF2B579A),
  );
  static const _excel = _FileTypeStyle(
    icon: Icons.table_chart_rounded,
    label: 'XLS',
    color: Color(0xFF217346),
  );
  static const _ppt = _FileTypeStyle(
    icon: Icons.slideshow_rounded,
    label: 'PPT',
    color: Color(0xFFC43E1C),
  );
  static const _pdf = _FileTypeStyle(
    icon: Icons.picture_as_pdf_rounded,
    label: 'PDF',
    color: Color(0xFFD32F2F),
  );
  static const _csv = _FileTypeStyle(
    icon: Icons.grid_on_rounded,
    label: 'CSV',
    color: Color(0xFF00897B),
  );
  static const _tsv = _FileTypeStyle(
    icon: Icons.view_column_rounded,
    label: 'TSV',
    color: Color(0xFF00838F),
  );
  static const _md = _FileTypeStyle(
    icon: Icons.code_rounded,
    label: 'MD',
    color: Color(0xFF6A1B9A),
  );
  static const _txt = _FileTypeStyle(
    icon: Icons.notes_rounded,
    label: 'TXT',
    color: Color(0xFF546E7A),
  );
  static const _json = _FileTypeStyle(
    icon: Icons.data_object_rounded,
    label: 'JSON',
    color: Color(0xFFF9A825),
  );
  static const _image = _FileTypeStyle(
    icon: Icons.image_rounded,
    label: 'IMG',
    color: Color(0xFF5C6BC0),
  );
  static const _file = _FileTypeStyle(
    icon: Icons.insert_drive_file_rounded,
    label: 'FILE',
    color: Color(0xFF78909C),
  );

  static _FileTypeStyle of(Attachment a) {
    if (a.isImage) return _image;
    final n = a.name.toLowerCase();
    if (n.endsWith('.pdf')) return _pdf;
    if (n.endsWith('.docx') || n.endsWith('.doc')) return _word;
    if (n.endsWith('.xlsx') || n.endsWith('.xls')) return _excel;
    if (n.endsWith('.pptx') || n.endsWith('.ppt')) return _ppt;
    if (n.endsWith('.csv')) return _csv;
    if (n.endsWith('.tsv')) return _tsv;
    if (n.endsWith('.md') || n.endsWith('.markdown')) return _md;
    if (n.endsWith('.txt') || n.endsWith('.log')) return _txt;
    if (n.endsWith('.json')) return _json;
    // Fallback: use extension stem as label when short enough.
    final dot = n.lastIndexOf('.');
    if (dot >= 0 && dot < n.length - 1) {
      final ext = n.substring(dot + 1);
      if (ext.length <= 4) {
        return _FileTypeStyle(
          icon: Icons.insert_drive_file_rounded,
          label: ext.toUpperCase(),
          color: _file.color,
        );
      }
    }
    return _file;
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

  /// When true, ask the codec to decode near bubble width (saves RAM).
  /// Some Windows/codec combos fail with cacheWidth — we fall back once.
  bool _preferCachedDecode = true;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(AttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.imageBase64 != widget.attachment.imageBase64 ||
        oldWidget.attachment.remoteUrl != widget.attachment.remoteUrl) {
      _preferCachedDecode = true;
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

  bool get _canOpen {
    final b64 = widget.attachment.imageBase64;
    if (b64 != null && b64.isNotEmpty) return true;
    final url = widget.attachment.remoteUrl;
    return url != null && url.isNotEmpty;
  }

  void _openViewer(BuildContext context) {
    if (!_canOpen) return;
    unawaited(ImageViewerPage.open(context, widget.attachment));
  }

  void _disableCachedDecode() {
    if (!_preferCachedDecode || !mounted) return;
    // Defer setState so we are not rebuilding during errorBuilder paint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _preferCachedDecode) {
        setState(() => _preferCachedDecode = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = _bytes;
    final remoteUrl = widget.attachment.remoteUrl;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Only pass cacheWidth when preferred — never force a broken decode path.
    final int? cachePx = _preferCachedDecode
        ? (640 * dpr).round().clamp(320, 1920)
        : null;
    Widget image;
    if (bytes != null) {
      image = Image.memory(
        bytes,
        fit: BoxFit.contain,
        cacheWidth: cachePx,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) {
          // cacheWidth can fail on some codecs/platforms — retry full decode.
          if (_preferCachedDecode) {
            _disableCachedDecode();
            return const SizedBox(width: 240, height: 140);
          }
          return _error(scheme);
        },
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
        cacheWidth: cachePx,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) {
          if (_preferCachedDecode) {
            _disableCachedDecode();
            return const SizedBox(width: 240, height: 140);
          }
          return _error(scheme);
        },
      );
    } else {
      image = _error(scheme);
    }
    return Semantics(
      image: true,
      button: _canOpen,
      label: widget.attachment.name,
      hint: _canOpen ? '点击查看大图，可保存或分享' : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _canOpen ? () => _openViewer(context) : null,
          borderRadius: BorderRadius.circular(16),
          // Ensure empty/decoding frames still receive taps.
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: 120,
                minHeight: 80,
                maxWidth: 640,
                maxHeight: 640,
              ),
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  image,
                  if (_canOpen &&
                      !_decoding &&
                      (bytes != null ||
                          (remoteUrl != null && remoteUrl.isNotEmpty)))
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color(0x73000000),
                          borderRadius: BorderRadius.all(Radius.circular(999)),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(
                            Icons.open_in_full_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
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
