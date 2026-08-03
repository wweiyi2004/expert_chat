import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/models.dart';

/// One image candidate waiting for user confirm after system file pick.
class PendingImagePick {
  PendingImagePick({required this.attachment, this.selected = true});

  final Attachment attachment;
  bool selected;
}

/// Horizontal strip: thumbnails + checkboxes, then 取消 / 添加.
///
/// Shown above the composer after「上传图片」returns from the system picker.
class ImagePickConfirmBar extends StatelessWidget {
  const ImagePickConfirmBar({
    super.key,
    required this.candidates,
    required this.maxSelectable,
    required this.onChanged,
    required this.onCancel,
    required this.onConfirm,
  });

  final List<PendingImagePick> candidates;
  final int maxSelectable;
  final VoidCallback onChanged;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  int get _selectedCount =>
      candidates.where((c) => c.selected).length;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedCount;
    final canAdd = selected > 0 && selected <= maxSelectable;

    return Material(
      elevation: 2,
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.photo_library_outlined, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      maxSelectable <= 1
                          ? '选择要添加的图片（最多 1 张）'
                          : '勾选要添加的图片（已选 $selected / 最多 $maxSelectable）',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 96,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: candidates.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final item = candidates[index];
                    return _PickThumb(
                      attachment: item.attachment,
                      selected: item.selected,
                      onTap: () {
                        // Single-slot: radio behavior.
                        if (maxSelectable <= 1) {
                          for (final c in candidates) {
                            c.selected = identical(c, item);
                          }
                        } else {
                          if (!item.selected && selected >= maxSelectable) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('最多只能选 $maxSelectable 张'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                            return;
                          }
                          item.selected = !item.selected;
                        }
                        onChanged();
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton(onPressed: onCancel, child: const Text('取消')),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: canAdd ? onConfirm : null,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(canAdd ? '添加 ($selected)' : '请勾选图片'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickThumb extends StatelessWidget {
  const _PickThumb({
    required this.attachment,
    required this.selected,
    required this.onTap,
  });

  final Attachment attachment;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = _decodeThumb(attachment.imageBase64);
    return Semantics(
      button: true,
      selected: selected,
      label: attachment.name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          width: 88,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: bytes != null
                    ? Image.memory(
                        bytes,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (_, _, _) => _fallback(scheme),
                      )
                    : _fallback(scheme),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary
                        : scheme.surface.withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? scheme.primary : scheme.outline,
                    ),
                  ),
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    selected ? Icons.check_rounded : Icons.circle_outlined,
                    size: 16,
                    color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (attachment.parseError != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: scheme.errorContainer.withValues(alpha: 0.92),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      '无效',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallback(ColorScheme scheme) => ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
      );

  static Uint8List? _decodeThumb(String? b64) {
    if (b64 == null || b64.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(b64));
    } catch (_) {
      return null;
    }
  }
}
