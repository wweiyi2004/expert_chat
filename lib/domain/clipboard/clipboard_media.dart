import 'package:flutter/foundation.dart';

import 'clipboard_media_stub.dart'
    if (dart.library.io) 'clipboard_media_io.dart';

/// Files and/or a bitmap copied to the system clipboard.
class ClipboardMedia {
  const ClipboardMedia({this.filePaths = const [], this.imageBytes});

  final List<String> filePaths;
  final Uint8List? imageBytes;

  bool get hasFiles => filePaths.isNotEmpty;
  bool get hasImage => imageBytes != null && imageBytes!.isNotEmpty;
  bool get hasAttachable => hasFiles || hasImage;
}

typedef ClipboardMediaReader = Future<ClipboardMedia> Function();

/// Overridable so widget tests can paste files/images without a real clipboard.
ClipboardMediaReader clipboardMediaReader = readClipboardMediaImpl;

Future<ClipboardMedia> readClipboardMedia() => clipboardMediaReader();

@visibleForTesting
void debugResetClipboardMediaReader() {
  clipboardMediaReader = readClipboardMediaImpl;
}

String fileNameFromPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? path : normalized.substring(slash + 1);
}

String? extensionOfName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// File name + mime for a clipboard bitmap that has no original filename.
({String name, String mimeType, String extension}) clipboardImageIdentity(
  Uint8List bytes,
) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return (name: 'clipboard.png', mimeType: 'image/png', extension: 'png');
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return (name: 'clipboard.jpg', mimeType: 'image/jpeg', extension: 'jpg');
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return (name: 'clipboard.gif', mimeType: 'image/gif', extension: 'gif');
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return (name: 'clipboard.webp', mimeType: 'image/webp', extension: 'webp');
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return (name: 'clipboard.bmp', mimeType: 'image/bmp', extension: 'bmp');
  }
  return (name: 'clipboard.png', mimeType: 'image/png', extension: 'png');
}
