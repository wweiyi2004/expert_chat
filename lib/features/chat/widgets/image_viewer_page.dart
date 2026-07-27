import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/models.dart';

/// Full-screen image viewer with pinch-zoom, save and share.
///
/// Opened by tapping a generated (or attached) image in chat. Save uses the
/// system file picker (Storage Access Framework on Android — no extra
/// storage permission). Share uses the platform share sheet so the user can
/// send the image or save it to Photos / Files from there.
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({super.key, required this.attachment});

  final Attachment attachment;

  static Future<void> open(BuildContext context, Attachment attachment) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ImageViewerPage(attachment: attachment),
      ),
    );
  }

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  Uint8List? _bytes;
  Object? _loadError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBytes());
  }

  Future<void> _loadBytes() async {
    try {
      final b64 = widget.attachment.imageBase64;
      if (b64 != null && b64.isNotEmpty) {
        // Mirror AttachmentImage: small payloads decode on the UI isolate so
        // the first frame can already show save/share actions; large ones use
        // compute() to avoid jank.
        final Uint8List? decoded;
        if (b64.length < 256 * 1024) {
          decoded = _decodeBase64Safe(b64);
        } else {
          decoded = await compute(_decodeBase64Safe, b64);
        }
        if (!mounted) return;
        setState(() {
          _bytes = decoded;
          if (decoded == null) _loadError = '图片数据无效';
        });
        return;
      }
      final url = widget.attachment.remoteUrl?.trim() ?? '';
      if (url.isEmpty) {
        if (!mounted) return;
        setState(() => _loadError = '没有可显示的图片数据');
        return;
      }
      final response = await Dio().get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (!mounted) return;
      if (data == null || data.isEmpty) {
        setState(() => _loadError = '下载图片失败');
        return;
      }
      setState(() => _bytes = Uint8List.fromList(data));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e);
    }
  }

  String get _fileName {
    final name = widget.attachment.name.trim();
    if (name.isNotEmpty) return name;
    final mime = widget.attachment.mimeType.toLowerCase();
    final ext = mime.contains('jpeg') || mime.contains('jpg')
        ? 'jpg'
        : mime.contains('webp')
            ? 'webp'
            : mime.contains('gif')
                ? 'gif'
                : 'png';
    return 'expert-chat-${DateTime.now().millisecondsSinceEpoch}.$ext';
  }

  Future<void> _save() async {
    final bytes = _bytes;
    if (bytes == null || _busy) return;
    setState(() => _busy = true);
    try {
      final isMobile = !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      final path = await FilePicker.saveFile(
        dialogTitle: '保存图片',
        fileName: _fileName,
        type: FileType.image,
        bytes: isMobile ? bytes : null,
      );
      if (path == null) return;
      if (!isMobile) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      if (!mounted) return;
      _toast('已保存');
    } catch (e) {
      if (!mounted) return;
      _toast('保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    final bytes = _bytes;
    if (bytes == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (kIsWeb) {
        // Web share of binary files is flaky; fall back to save dialog.
        await _save();
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}$_fileName',
      );
      await file.writeAsBytes(bytes, flush: true);
      final mime = widget.attachment.mimeType.isNotEmpty
          ? widget.attachment.mimeType
          : 'image/png';
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mime, name: _fileName)],
          subject: _fileName,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('分享失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = _bytes;
    final error = _loadError;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.attachment.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          if (bytes != null) ...[
            IconButton(
              tooltip: '保存',
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.download_outlined),
            ),
            IconButton(
              tooltip: '分享',
              onPressed: _busy ? null : _share,
              icon: const Icon(Icons.share_outlined),
            ),
          ],
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (bytes != null)
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Center(
                // Avoid cacheWidth here: full-screen viewer must show a
                // reliable full decode; list bubbles already downscale.
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, _, _) => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '图片无法解码',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
            )
          else if (error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.broken_image_outlined,
                      size: 48,
                      color: scheme.onInverseSurface,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '无法打开图片',
                      style: TextStyle(color: scheme.onInverseSurface),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$error',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: scheme.onInverseSurface.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (_busy)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Uint8List? _decodeBase64Safe(String value) {
  try {
    var payload = value.trim();
    if (payload.startsWith('data:')) {
      final comma = payload.indexOf(',');
      if (comma > 0) payload = payload.substring(comma + 1);
    }
    if (payload.contains(RegExp(r'\s'))) {
      payload = payload.replaceAll(RegExp(r'\s'), '');
    }
    if (payload.contains('-') || payload.contains('_')) {
      payload = payload.replaceAll('-', '+').replaceAll('_', '/');
    }
    final pad = (4 - payload.length % 4) % 4;
    if (pad != 0) payload = payload.padRight(payload.length + pad, '=');
    return base64Decode(payload);
  } on FormatException {
    return null;
  }
}

