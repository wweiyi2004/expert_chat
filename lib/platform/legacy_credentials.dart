import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:pointycastle/export.dart';
import 'package:path/path.dart' as p;

const _prefix = 'expert_chat_VGhpcyBpcyB0aGUgcHJlZml4IGZv_';
typedef _EnumerateNative =
    Int32 Function(
      Pointer<Utf16>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Pointer<Pointer<CREDENTIAL>>>,
    );
typedef _EnumerateDart =
    int Function(
      Pointer<Utf16>,
      int,
      Pointer<Uint32>,
      Pointer<Pointer<Pointer<CREDENTIAL>>>,
    );

/// Read only the legacy namespace belonging to this application. No legacy
/// source is deleted or rewritten; the caller commits DPAPI data then a marker.
Future<Map<String, String>> readLegacyCredentials(
  Directory directory, {
  String namespace = _prefix,
}) async {
  if (!namespace.startsWith('expert_chat_') ||
      namespace.contains(RegExp(r'[\x00*?]'))) {
    throw ArgumentError('Invalid legacy namespace');
  }
  final values = <String, String>{};
  using((arena) {
    final enumerate = DynamicLibrary.open(
      'advapi32.dll',
    ).lookupFunction<_EnumerateNative, _EnumerateDart>('CredEnumerateW');
    final count = arena<Uint32>(),
        output = arena<Pointer<Pointer<CREDENTIAL>>>();
    if (enumerate(
          '$namespace*'.toNativeUtf16(allocator: arena),
          0,
          count,
          output,
        ) ==
        0) {
      if (GetLastError() != ERROR_NOT_FOUND) throw StateError('无法读取旧凭据，原内容已保留');
      return;
    }
    try {
      if (count.value > 10000) throw StateError('旧凭据数量超限');
      for (var i = 0; i < count.value; i++) {
        final cred = output.value[i].ref, name = cred.TargetName.toDartString();
        if (!name.startsWith(namespace) || cred.Type != CRED_TYPE_GENERIC) {
          continue;
        }
        if (cred.CredentialBlobSize > 1024 * 1024) throw StateError('旧凭据大小超限');
        final bytes = Uint8List.fromList(
          cred.CredentialBlob.asTypedList(cred.CredentialBlobSize),
        );
        try {
          values[name.substring(namespace.length)] = utf8.decode(
            bytes.takeWhile((b) => b != 0).toList(),
          );
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
    } finally {
      CredFree(output.value);
    }
  });
  final files = await directory
      .list(followLinks: false)
      .where(
        (e) =>
            e is File &&
            p.basename(e.path).startsWith(namespace) &&
            e.path.endsWith('.secure'),
      )
      .cast<File>()
      .toList();
  if (files.isEmpty) return values;
  if (files.length > 10000) throw StateError('旧凭据文件数量超限');
  final key = using((arena) {
    final output = arena<Pointer<CREDENTIAL>>();
    if (CredRead(
          'key_$namespace'.toNativeUtf16(allocator: arena),
          CRED_TYPE_GENERIC,
          0,
          output,
        ) ==
        0) {
      throw StateError('旧凭据解密密钥不可用');
    }
    try {
      if (output.value.ref.CredentialBlobSize != 16) {
        throw StateError('旧凭据密钥无效');
      }
      return Uint8List.fromList(
        output.value.ref.CredentialBlob.asTypedList(16),
      );
    } finally {
      CredFree(output.value);
    }
  });
  try {
    for (final file in files) {
      if (await file.length() > 1024 * 1024) throw StateError('旧凭据文件大小超限');
      final bytes = await file.readAsBytes();
      if (bytes.length < 28) throw StateError('旧凭据文件损坏，原文件已保留');
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(key),
            128,
            Uint8List.sublistView(bytes, 0, 12),
            Uint8List(0),
          ),
        );
      final encrypted = Uint8List.fromList([
        ...bytes.skip(28),
        ...bytes.sublist(12, 28),
      ]);
      final plain = cipher.process(encrypted);
      try {
        final name = p.basename(file.path);
        values[name.substring(namespace.length, name.length - 7)] = utf8.decode(
          plain,
        );
      } finally {
        plain.fillRange(0, plain.length, 0);
        cipher.reset();
      }
    }
  } finally {
    key.fillRange(0, key.length, 0);
  }
  return values;
}
