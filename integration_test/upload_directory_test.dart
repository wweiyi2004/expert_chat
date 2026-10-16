import 'dart:convert';
import 'dart:io';

import 'package:expert_chat/domain/tools/upload_directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The host creates synthetic files on a disposable emulator and selects their
/// exact directory through the real Android picker after the READY marker.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android SAF lists the chosen directory, reads files and restores its grant',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('目录授权验证'))),
        ),
      );
      await tester.runAsync(() async {
        const browser = UploadDirectoryBrowser();
        // This marker is consumed by the native acceptance harness.
        // ignore: avoid_print
        print('UPLOAD_DIRECTORY_READY');
        final picked = await browser.choose().timeout(
          const Duration(minutes: 3),
        );
        expect(picked, isNotNull);
        expect(picked!.name, 'ExpertChatUploadTest20261005');
        final files = picked.entries
            .where((entry) => !entry.isDirectory)
            .toList();
        expect(
          files
              .map((entry) => entry.name)
              .where((name) => name.endsWith('.txt')),
          ['z-new.txt', 'a-old.txt'],
        );
        final recent = files.firstWhere((entry) => entry.name == 'z-new.txt');
        expect(
          utf8.decode(
            (await browser.readBytes(root: picked.root, entry: recent))!,
          ),
          'new synthetic document',
        );
        final child = picked.entries.firstWhere(
          (entry) => entry.isDirectory && entry.name == 'child',
        );
        final children = await browser.list(root: picked.root, uri: child.uri);
        expect(children.entries.single.name, 'nested.txt');
        expect(
          utf8.decode(
            (await browser.readBytes(
              root: children.root,
              entry: children.entries.single,
            ))!,
          ),
          'nested synthetic document',
        );
        final restored = await browser.restore();
        expect(restored!.root, picked.root);
        expect(
          restored.entries.map((entry) => entry.name),
          picked.entries.map((entry) => entry.name),
        );
        await expectLater(
          browser.list(
            root: picked.root,
            uri:
                'content://com.android.externalstorage.documents/tree/primary%3AOther/document/primary%3AOther',
          ),
          throwsA(isA<PlatformException>()),
        );
        final large = files.firstWhere(
          (entry) => entry.name == 'too-large.bin',
        );
        await expectLater(
          const MethodChannel(
            'expert_chat/upload_directory',
          ).invokeMethod<Uint8List>('read', {
            'root': picked.root,
            'uri': large.uri,
          }),
          throwsA(isA<PlatformException>()),
        );
        // ignore: avoid_print
        print(
          'UPLOAD_DIRECTORY_RESULT ${jsonEncode({'passed': true, 'files': files.length, 'childDirectories': picked.entries.where((entry) => entry.isDirectory).length, 'restored': true, 'outsideRejected': true, 'oversizeRejected': true})}',
        );
      });
    },
    skip: !Platform.isAndroid,
  );
}
