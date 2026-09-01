import 'dart:convert';
import 'dart:typed_data';

import 'package:expert_chat/domain/clipboard/clipboard_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fileNameFromPath keeps the basename on Windows and POSIX paths', () {
    expect(fileNameFromPath(r'C:\Users\me\shot.png'), 'shot.png');
    expect(fileNameFromPath('/tmp/notes.md'), 'notes.md');
    expect(fileNameFromPath('plain.txt'), 'plain.txt');
  });

  test('clipboardImageIdentity reads magic bytes', () {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    expect(clipboardImageIdentity(png).name, 'clipboard.png');
    expect(clipboardImageIdentity(png).mimeType, 'image/png');

    final jpeg = Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]);
    expect(clipboardImageIdentity(jpeg).extension, 'jpg');

    final bmp = Uint8List.fromList(const [0x42, 0x4D, 0x00, 0x00]);
    expect(clipboardImageIdentity(bmp).name, 'clipboard.bmp');
  });

  test('ClipboardMedia reports attachable files or image bytes', () {
    expect(const ClipboardMedia().hasAttachable, isFalse);
    expect(
      const ClipboardMedia(filePaths: [r'C:\a.pdf']).hasAttachable,
      isTrue,
    );
    expect(
      ClipboardMedia(imageBytes: Uint8List.fromList(const [1, 2, 3])).hasImage,
      isTrue,
    );
  });
}
