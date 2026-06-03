import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../data/models.dart';

/// Compact file card shown in the composer (and on user message bubbles).
/// Surfaces the file name, a status line (size / truncated / parse error) and,
/// when [onRemove] is given, a remove button.
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({super.key, required this.attachment, this.onRemove});

  final Attachment attachment;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasError = attachment.parseError != null;
    final color = hasError ? scheme.error : scheme.primary;

    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
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
                    fontWeight: FontWeight.w500,
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
          if (onRemove != null) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(8),
              child: Icon(
                Icons.close,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A small image thumbnail when the attachment is a retained image, else the
  /// type icon.
  Widget _leading(Color color) {
    if (attachment.hasImageData) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          base64Decode(attachment.imageBase64!),
          width: 28,
          height: 28,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              Icon(_iconFor(attachment), size: 20, color: color),
        ),
      );
    }
    return Icon(_iconFor(attachment), size: 20, color: color);
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
