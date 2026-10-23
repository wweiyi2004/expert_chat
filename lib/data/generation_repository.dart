import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../domain/media/image_edit_reference.dart';
import 'db/app_database.dart';
import 'library_repository.dart';
import 'media_api_config.dart';
import 'models.dart' show Attachment;

/// Metadata records are per request, not per image hash. Identical output
/// bytes may share a library item without collapsing distinct versions.
class GenerationRepository {
  GenerationRepository(this.db, this.library);
  final AppDatabase db;
  final LibraryRepository library;
  static String providerOrigin(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
            uri.hasAuthority &&
            (uri.scheme == 'http' || uri.scheme == 'https')
        ? uri.origin
        : '';
  }

  Future<List<GenerationRecord>> list({String? libraryItemId}) {
    final query = db.select(db.generationRecords)
      ..orderBy([(r) => OrderingTerm.desc(r.createdAt)]);
    if (libraryItemId != null) {
      query.where((r) => r.libraryItemId.equals(libraryItemId));
    }
    return query.get();
  }

  Future<GenerationRecord?> get(String id) => (db.select(
    db.generationRecords,
  )..where((r) => r.id.equals(id))).getSingleOrNull();

  Future<String> record({
    required Attachment output,
    required MediaApiConfig config,
    required String originalPrompt,
    required String sentPrompt,
    String? revisedPrompt,
    required String conversationId,
    required String messageId,
    String? parentGenerationId,
    List<ImageEditReference> references = const [],
  }) async {
    String? outputId;
    final archiveErrors = <String>[];
    if (output.hasDownloadableBytes) {
      try {
        final item = await library.importBytes(
          name: output.name,
          mimeType: output.mimeType,
          bytes: base64Decode(output.imageBase64!),
        );
        outputId = item.id;
      } catch (e) {
        archiveErrors.add('输出图片：$e');
      }
    }
    final refs = <Map<String, dynamic>>[];
    for (final reference in references) {
      String? referenceId;
      final bytes = Uint8List.fromList(reference.bytes);
      try {
        final item = await library.importBytes(
          name: reference.fileName,
          mimeType: reference.mimeType,
          bytes: bytes,
        );
        referenceId = item.id;
      } catch (e) {
        archiveErrors.add('参考图：$e');
      }
      refs.add({
        'libraryItemId': referenceId,
        'sha256': sha256.convert(bytes).toString(),
        'name': reference.fileName,
      });
    }
    final id = const Uuid().v4();
    await db
        .into(db.generationRecords)
        .insert(
          GenerationRecordsCompanion.insert(
            id: id,
            libraryItemId: Value(outputId),
            conversationId: Value(conversationId),
            messageId: Value(messageId),
            parentGenerationId: Value(parentGenerationId),
            originalPrompt: originalPrompt,
            optimizedPrompt: sentPrompt,
            revisedPrompt: Value(revisedPrompt),
            model: config.model.trim(),
            providerHost: providerOrigin(config.baseUrl),
            apiFormat: Value(config.effectiveApiFormat.wire),
            imageSize: config.imageSize.trim(),
            referencesJson: Value(jsonEncode(refs)),
            createdAt: DateTime.now(),
          ),
        );
    if (archiveErrors.isNotEmpty) {
      throw StateError('版本参数已保存，但素材归档失败：${archiveErrors.join('；')}');
    }
    return id;
  }

  Future<List<Attachment>> references(GenerationRecord record) async {
    final rows = jsonDecode(record.referencesJson) as List;
    final attachments = <Attachment>[];
    for (final row in rows) {
      if (row['libraryItemId'] is! String) {
        throw StateError('原参考图未能归档，无法按原参数生成。');
      }
      final item = await library.getById(row['libraryItemId'] as String);
      final bytes = item == null ? null : await library.readBytes(item);
      if (item == null ||
          bytes == null ||
          sha256.convert(bytes).toString() != row['sha256']) {
        throw StateError('参考图缺失或已修改，不能按原参数生成。请重新添加参考图。');
      }
      attachments.add(
        Attachment(
          name: row['name'] as String,
          mimeType: item.mimeType,
          sizeBytes: bytes.length,
          imageBase64: base64Encode(bytes),
        ),
      );
    }
    return attachments;
  }
}
