import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pasteboard/pasteboard.dart';

import 'clipboard_media.dart';

Future<ClipboardMedia> readClipboardMediaImpl() async {
  if (Platform.isAndroid) return const ClipboardMedia();

  var filePaths = const <String>[];
  try {
    filePaths = [
      for (final path in await Pasteboard.files())
        if (path.trim().isNotEmpty) path,
    ];
  } catch (_) {}

  Uint8List? imageBytes;
  if (filePaths.isEmpty) {
    try {
      imageBytes = await Pasteboard.image;
    } catch (_) {}
    if (imageBytes == null || imageBytes.isEmpty) {
      imageBytes = _readWindowsClipboardPng();
    }
  }

  return ClipboardMedia(
    filePaths: filePaths,
    imageBytes: imageBytes == null || imageBytes.isEmpty ? null : imageBytes,
  );
}

/// Snipping Tool / some browsers put PNG on the clipboard without CF_DIB.
Uint8List? _readWindowsClipboardPng() {
  if (!Platform.isWindows) return null;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final openClipboard = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'OpenClipboard',
        );
    final closeClipboard = user32
        .lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
    final isClipboardFormatAvailable = user32
        .lookupFunction<Int32 Function(Uint32), int Function(int)>(
          'IsClipboardFormatAvailable',
        );
    final getClipboardData = user32
        .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
          'GetClipboardData',
        );
    final registerClipboardFormat = user32
        .lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)
        >('RegisterClipboardFormatW');
    final globalLock = kernel32
        .lookupFunction<
          Pointer<Void> Function(IntPtr),
          Pointer<Void> Function(int)
        >('GlobalLock');
    final globalUnlock = kernel32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'GlobalUnlock',
        );
    final globalSize = kernel32
        .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
          'GlobalSize',
        );

    final formatName = 'PNG'.toNativeUtf16();
    final pngFormat = registerClipboardFormat(formatName);
    malloc.free(formatName);
    if (pngFormat == 0) return null;
    if (openClipboard(0) == 0) return null;
    try {
      if (isClipboardFormatAvailable(pngFormat) == 0) return null;
      final handle = getClipboardData(pngFormat);
      if (handle == 0) return null;
      final size = globalSize(handle);
      if (size <= 0) return null;
      final ptr = globalLock(handle);
      if (ptr == nullptr) return null;
      try {
        return Uint8List.fromList(ptr.cast<Uint8>().asTypedList(size));
      } finally {
        globalUnlock(handle);
      }
    } finally {
      closeClipboard();
    }
  } catch (_) {
    return null;
  }
}
