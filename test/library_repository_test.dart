import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/library_file_store.dart';
import 'package:expert_chat/data/library_models.dart';
import 'package:expert_chat/data/library_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated image names use date and a prompt slug', () {
    final name = libraryGeneratedImageName(
      prompt: '华中科技大学图书馆 红砖老馆',
      mimeType: 'image/png',
      at: DateTime(2026, 9, 1, 15, 30, 12),
    );
    expect(name, '生图-20260901-153012-华中科技大学图书.png');
    expect(
      libraryGeneratedImageName(
        prompt: '  ',
        mimeType: 'image/jpeg',
        at: DateTime(2026, 9, 1, 8, 5, 6),
      ),
      '生图-20260901-080506.jpg',
    );
    expect(libraryImageSlug('a/b:c*d?.png'), 'abcdpng');
  });

  test('library imports, dedupes, lists, and deletes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dir = await Directory.systemTemp.createTemp('library_test_');
    addTearDown(() => dir.delete(recursive: true));
    final repo = LibraryRepository(
      db,
      LibraryFileStore(rootOverride: dir.path),
    );

    final first = await repo.importBytes(
      name: 'a.png',
      mimeType: 'image/png',
      bytes: Uint8List.fromList(List<int>.filled(32, 7)),
    );
    expect(first.kind, LibraryItemKind.image);
    expect(first.name, 'a.png');

    final duplicate = await repo.importBytes(
      name: 'b.png',
      mimeType: 'image/png',
      bytes: Uint8List.fromList(List<int>.filled(32, 7)),
    );
    expect(duplicate.id, first.id);

    final other = await repo.importBytes(
      name: 'note.txt',
      mimeType: 'text/plain',
      bytes: Uint8List.fromList('hello'.codeUnits),
    );
    expect(other.kind, LibraryItemKind.file);

    final images = await repo.list(kind: LibraryItemKind.image);
    expect(images, hasLength(1));
    final files = await repo.list(kind: LibraryItemKind.file);
    expect(files, hasLength(1));

    final attachment = await repo.toAttachment(first);
    expect(attachment, isNotNull);
    expect(attachment!.hasImageData, isTrue);

    await repo.delete(first.id);
    expect(await repo.list(kind: LibraryItemKind.image), isEmpty);
    expect(await repo.list(kind: LibraryItemKind.file), hasLength(1));
  });
}
