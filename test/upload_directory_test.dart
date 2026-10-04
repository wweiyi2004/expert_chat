import 'dart:io';
import 'dart:convert';

import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:expert_chat/domain/tools/upload_directory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'selected directory lists actual children newest first and reads confirmed files',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        'expert-chat-directory-test-',
      );
      addTearDown(() async {
        final resolved = await fixture.resolveSymbolicLinks();
        expect(
          p.isWithin(Directory.systemTemp.absolute.path, resolved),
          isTrue,
        );
        expect(p.basename(resolved), startsWith('expert-chat-directory-test-'));
        await fixture.delete(recursive: true);
      });
      final root = await Directory(p.join(fixture.path, 'selected')).create();
      final old = File(p.join(root.path, 'a-old.txt'));
      final recent = File(p.join(root.path, 'z-new.txt'));
      await old.writeAsString('旧文件');
      await recent.writeAsString('新文件');
      await old.setLastModified(DateTime(2026, 10, 1));
      await recent.setLastModified(DateTime(2026, 10, 5));
      await Directory(p.join(root.path, 'child')).create();
      final outside = File(p.join(fixture.path, 'outside.txt'));
      await outside.writeAsString('outside selection');
      const browser = UploadDirectoryBrowser();
      final listed = await browser.list(root: root.path, uri: root.path);
      expect(listed.name, 'selected');
      expect(listed.entries.map((entry) => entry.name), [
        'child',
        'z-new.txt',
        'a-old.txt',
      ]);
      expect(
        utf8.decode(
          (await browser.readBytes(root: root.path, entry: listed.entries[1]))!,
        ),
        '新文件',
      );
      await expectLater(
        browser.list(root: root.path, uri: fixture.path),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        browser.readBytes(
          root: root.path,
          entry: UploadDirectoryEntry(
            uri: outside.path,
            name: 'outside.txt',
            isDirectory: false,
            sizeBytes: 17,
            modifiedAt: DateTime(2026),
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        browser.readBytes(
          root: root.path,
          entry: UploadDirectoryEntry(
            uri: recent.path,
            name: recent.path,
            isDirectory: false,
            sizeBytes: 11 * 1024 * 1024,
            modifiedAt: DateTime(2026),
          ),
        ),
        throwsA(isA<FileReadLimitExceeded>()),
      );
      SharedPreferences.setMockInitialValues({
        'attachment_upload_directory': root.path,
      });
      final restored = await browser.restore();
      expect(restored!.uri, listed.uri);
      expect(
        restored.entries.map((entry) => entry.name),
        listed.entries.map((entry) => entry.name),
      );
    },
  );

  test(
    'provider MIME types identify extensionless documents without inventing dates',
    () {
      final document = UploadDirectoryEntry(
        uri: 'content://test/file/1',
        name: '报告',
        isDirectory: false,
        sizeBytes: 100,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(0),
        mimeType: 'application/pdf',
      );
      expect(document.extension, 'pdf');
      expect(document.modifiedAt.millisecondsSinceEpoch, 0);
    },
  );
}
