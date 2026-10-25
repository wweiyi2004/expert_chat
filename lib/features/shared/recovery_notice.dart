import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/errors/app_failure.dart';

/// Shared recovery surface. Only callers that can safely replay an operation
/// provide onRetry; document writes and paid requests keep their own reviews.
class RecoveryNotice extends StatefulWidget {
  const RecoveryNotice({
    super.key,
    required this.error,
    this.title,
    this.guidance,
    this.onRetry,
    this.retryLabel = '重试',
    this.onConfigure,
    this.onDismiss,
    this.secrets = const [],
  });
  final Object error;
  final String? title;
  final String? guidance;
  final Future<void> Function()? onRetry;
  final String retryLabel;
  final VoidCallback? onConfigure;
  final VoidCallback? onDismiss;
  final Iterable<String> secrets;
  @override
  State<RecoveryNotice> createState() => _RecoveryNoticeState();
}

class _RecoveryNoticeState extends State<RecoveryNotice> {
  bool _busy = false;
  Object? _retryError;
  @override
  void didUpdateWidget(RecoveryNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.error != widget.error) _retryError = null;
  }

  Future<void> _retry() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _retryError = null;
    });
    try {
      await widget.onRetry!();
    } catch (e) {
      if (mounted) setState(() => _retryError = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = AppFailure.from(
      _retryError ?? widget.error,
      secrets: widget.secrets,
    );
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 20,
                  color: scheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title ?? failure.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
                if (widget.onDismiss != null)
                  IconButton(
                    key: const ValueKey('dismiss-recovery-notice'),
                    tooltip: '关闭提示',
                    onPressed: widget.onDismiss,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: scheme.onErrorContainer,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              failure.message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            if (widget.guidance != null) ...[
              const SizedBox(height: 6),
              Text(
                widget.guidance!,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (widget.onRetry != null)
                  TextButton.icon(
                    onPressed: _busy ? null : _retry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(_busy ? '正在重试…' : widget.retryLabel),
                  ),
                if (widget.onConfigure != null)
                  TextButton(
                    onPressed: _busy ? null : widget.onConfigure,
                    child: const Text('检查设置'),
                  ),
              ],
            ),
            Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('技术信息', style: TextStyle(fontSize: 12)),
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        failure.details,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: failure.details),
                        );
                        if (context.mounted) {
                          AppToastMessenger.maybeOf(context)?.showSnackBar(
                            const SnackBar(content: Text('已复制技术信息')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_outlined, size: 16),
                      label: const Text('复制技术信息'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
