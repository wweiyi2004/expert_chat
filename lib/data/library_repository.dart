import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'db/app_database.dart';
import 'library_file_store.dart';
import 'library_models.dart';
import 'models.dart';

const _uuid = Uuid();

class LibraryRepository {
  LibraryRepository(this._db, this._store);

  final AppDatabase _db;
  final LibraryFileStore _store;

  Future<String> get folderPath => _store.rootPath;

  Future<List<LibraryItem>> list({LibraryItemKind? kind}) async {
    final query = _db.select(_db.libraryItems)
      ..orderBy([(row) => OrderingTerm.desc(row.lastUsedAt)]);
    if (kind != null) {
      query.where((row) => row.kind.equals(kind.name));
    }
    final rows = await query.get();
    return [for (final row in rows) _toItem(row)];
  }

  Future<LibraryItem?> getById(String id) async {
    final row = await (_db.select(
      _db.libraryItems,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toItem(row);
  }

  /// Copy [bytes] into the library. Duplicate content (same sha256) is reused.
  Future<LibraryItem> importBytes({
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final digest = sha256.convert(bytes).toString();
    final existing = await (_db.select(
      _db.libraryItems,
    )..where((row) => row.sha256.equals(digest))).getSingleOrNull();
    if (existing != null) {
      final now = DateTime.now();
      await (_db.update(_db.libraryItems)
            ..where((row) => row.id.equals(existing.id)))
          .write(LibraryItemsCompanion(lastUsedAt: Value(now)));
      return _toItem(existing, lastUsedAt: now);
    }
    final id = _uuid.v4();
    final image = mimeType.startsWith('image/');
    final relative = await _store.writeBytes(
      id: id,
      fileName: name,
      image: image,
      bytes: bytes,
    );
    final now = DateTime.now();
    final item = LibraryItem(
      id: id,
      name: name,
      kind: image ? LibraryItemKind.image : LibraryItemKind.file,
      mimeType: mimeType,
      sizeBytes: bytes.lengthInBytes,
      relativePath: relative,
      sha256: digest,
      createdAt: now,
      lastUsedAt: now,
    );
    await _db
        .into(_db.libraryItems)
        .insert(
          LibraryItemsCompanion.insert(
            id: item.id,
            name: item.name,
            kind: item.kind.name,
            mimeType: item.mimeType,
            sizeBytes: Value(item.sizeBytes),
            relativePath: item.relativePath,
            sha256: item.sha256,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
          ),
        );
    return item;
  }

  Future<void> touch(String id) async {
    await (_db.update(_db.libraryItems)..where((row) => row.id.equals(id)))
        .write(LibraryItemsCompanion(lastUsedAt: Value(DateTime.now())));
  }

  Future<void> delete(String id) async {
    final item = await getById(id);
    if (item == null) return;
    await _store.delete(item.relativePath);
    await (_db.delete(
      _db.libraryItems,
    )..where((row) => row.id.equals(id))).go();
  }

  Future<Uint8List?> readBytes(LibraryItem item) =>
      _store.readBytes(item.relativePath);

  Future<Attachment?> toAttachment(LibraryItem item) async {
    final bytes = await _store.readBytes(item.relativePath);
    if (bytes == null || bytes.isEmpty) return null;
    await touch(item.id);
    return Attachment(
      name: item.name,
      mimeType: item.mimeType,
      sizeBytes: bytes.lengthInBytes,
      imageBase64: base64Encode(bytes),
    );
  }
}

LibraryItem _toItem(LibraryItemRow row, {DateTime? lastUsedAt}) => LibraryItem(
  id: row.id,
  name: row.name,
  kind: row.kind == LibraryItemKind.image.name
      ? LibraryItemKind.image
      : LibraryItemKind.file,
  mimeType: row.mimeType,
  sizeBytes: row.sizeBytes,
  relativePath: row.relativePath,
  sha256: row.sha256,
  createdAt: row.createdAt,
  lastUsedAt: lastUsedAt ?? row.lastUsedAt,
);
