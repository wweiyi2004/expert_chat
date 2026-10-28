import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:win32/win32.dart';
import 'package:expert_chat/platform/credentials_host.dart';
import 'package:expert_chat/platform/legacy_credentials.dart';
import 'package:expert_chat/platform/paths_host.dart';

void credential(String name, List<int> bytes) => using((arena) {
  final value = arena<CREDENTIAL>(), buffer = arena<Uint8>(bytes.length);
  buffer.asTypedList(bytes.length).setAll(0, bytes);
  value.ref
    ..Type = CRED_TYPE_GENERIC
    ..TargetName = name.toNativeUtf16(allocator: arena)
    ..CredentialBlob = buffer
    ..CredentialBlobSize = bytes.length
    ..Persist = CRED_PERSIST_SESSION;
  if (CredWrite(value, 0) == 0) {
    throw StateError('Synthetic credential setup failed');
  }
});
void main() {
  test(
    'DPAPI writes round-trip and corrupt storage cannot be overwritten',
    () async {
      final root = await Directory.systemTemp.createTemp('expert-dpapi-test-');
      HostPaths.stateDirectory = root.path;
      try {
        const storage = FlutterSecureStorage();
        await storage.write(key: 'synthetic', value: 'SYNTHETIC_SECRET');
        expect(await storage.read(key: 'synthetic'), 'SYNTHETIC_SECRET');
        final file = File('${root.path}/flutter_secure_storage.dat'),
            bytes = await file.readAsBytes();
        expect(
          utf8.decode(bytes, allowMalformed: true),
          isNot(contains('SYNTHETIC_SECRET')),
        );
        bytes[bytes.length - 1] ^= 255;
        await file.writeAsBytes(bytes, flush: true);
        await expectLater(
          storage.write(key: 'other', value: 'must not replace'),
          throwsA(anything),
        );
        expect(await file.readAsBytes(), bytes);
      } finally {
        HostPaths.stateDirectory = null;
        for (final file in await root.list().toList()) {
          await file.delete();
        }
        await root.delete();
      }
    },
    skip: !Platform.isWindows,
  );
  test(
    'legacy AES and credential-manager records migrate without deleting sources',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'expert-legacy-credentials-test-',
      );
      final namespace = 'expert_chat_test_${const Uuid().v4()}_';
      final key = Uint8List.fromList(List.generate(16, (i) => i + 1)),
          nonce = Uint8List.fromList(List.generate(12, (i) => i + 3));
      final keyName = 'key_$namespace', directName = '${namespace}direct';
      try {
        credential(keyName, key);
        credential(directName, [...utf8.encode('DIRECT_SYNTHETIC'), 0]);
        final cipher = GCMBlockCipher(AESEngine())
          ..init(
            true,
            AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
          );
        final encrypted = cipher.process(
          Uint8List.fromList(utf8.encode('FILE_SYNTHETIC')),
        );
        final bytes = [
          ...nonce,
          ...encrypted.sublist(encrypted.length - 16),
          ...encrypted.sublist(0, encrypted.length - 16),
        ];
        final file = File('${root.path}/${namespace}file.secure');
        await file.writeAsBytes(bytes, flush: true);
        expect(await readLegacyCredentials(root, namespace: namespace), {
          'direct': 'DIRECT_SYNTHETIC',
          'file': 'FILE_SYNTHETIC',
        });
        expect(await file.readAsBytes(), bytes);
      } finally {
        using((arena) {
          for (final name in [keyName, directName]) {
            CredDelete(
              name.toNativeUtf16(allocator: arena),
              CRED_TYPE_GENERIC,
              0,
            );
          }
        });
        key.fillRange(0, key.length, 0);
        for (final file in await root.list().toList()) {
          await file.delete();
        }
        await root.delete();
      }
    },
    skip: !Platform.isWindows,
  );
}
