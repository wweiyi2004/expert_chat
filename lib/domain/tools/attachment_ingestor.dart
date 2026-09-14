import 'dart:convert';
import 'dart:typed_data';

import '../../data/models.dart';
import '../media/image_codec_util.dart';
import 'file_parser.dart';
import 'local_file_reader.dart';

/// A selected file, clipboard payload, or lazily loaded album image.
class FileIngestSource {
  const FileIngestSource({
    required this.name,
    this.extension,
    this.path,
    this.bytes,
    this.reportedSize,
    this.stream,
    this.loadBytes,
  });

  final String name;
  final String? extension;
  final String? path;
  final Uint8List? bytes;
  final int? reportedSize;
  final Stream<List<int>>? stream;
  final Future<Uint8List?> Function()? loadBytes;
}

class AttachmentIngestResult {
  AttachmentIngestResult({
    List<Attachment> attachments = const [],
    this.tooMany = 0,
    this.tooLarge = 0,
    this.overTotal = 0,
    this.unreadable = 0,
    this.cancelled = false,
  }) : attachments = List.unmodifiable(attachments);

  final List<Attachment> attachments;
  final int tooMany;
  final int tooLarge;
  final int overTotal;
  final int unreadable;
  final bool cancelled;
}

/// Prepares attachments without owning a widget, picker or conversation.
/// The caller checks its origin while asynchronous work is in progress and
/// decides whether prepared images need confirmation or can be attached now.
class AttachmentIngestor {
  const AttachmentIngestor({required this.parser});

  final FileParser parser;
  static const maxAttachments = 8;
  static const maxAttachmentBytes = 10 * 1024 * 1024;
  static const maxTotalAttachmentBytes = 48 * 1024 * 1024;
  static const documentExtensions = [
    'pdf',
    'docx',
    'xlsx',
    'pptx',
    'txt',
    'md',
    'csv',
    'tsv',
    'json',
  ];
  static const imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];

  Future<AttachmentIngestResult> ingest(
    List<FileIngestSource> sources, {
    required int slots,
    required int existingBytes,
    required bool Function() isCurrent,
  }) async {
    final additions = <Attachment>[];
    var runningTotal = existingBytes;
    var tooMany = 0;
    var tooLarge = 0;
    var overTotal = 0;
    var unreadable = 0;
    for (final source in sources) {
      if (!isCurrent()) return AttachmentIngestResult(cancelled: true);
      if (additions.length >= slots) {
        tooMany++;
        continue;
      }
      final reported = source.reportedSize ?? 0;
      if (reported > maxAttachmentBytes) {
        tooLarge++;
        continue;
      }
      final remainingTotal = maxTotalAttachmentBytes - runningTotal;
      if (remainingTotal <= 0) {
        overTotal++;
        continue;
      }
      final readLimit = remainingTotal < maxAttachmentBytes
          ? remainingTotal
          : maxAttachmentBytes;
      try {
        final Uint8List bytes;
        if (source.bytes != null) {
          bytes = source.bytes!;
        } else if (source.loadBytes != null) {
          final loaded = await source.loadBytes!();
          if (!isCurrent()) return AttachmentIngestResult(cancelled: true);
          if (loaded == null || loaded.isEmpty) {
            unreadable++;
            continue;
          }
          bytes = loaded;
        } else {
          final stream = source.stream ?? openLocalFileReadStream(source.path);
          if (stream == null) {
            unreadable++;
            continue;
          }
          bytes = await FileParser.readBytesWithLimit(
            stream,
            maxBytes: readLimit,
          );
        }
        if (!isCurrent()) return AttachmentIngestResult(cancelled: true);
        final size = reported > bytes.lengthInBytes
            ? reported
            : bytes.lengthInBytes;
        if (size > maxAttachmentBytes) {
          tooLarge++;
          continue;
        }
        if (runningTotal + size > maxTotalAttachmentBytes) {
          overTotal++;
          continue;
        }
        final mimeType = mimeFor(source.extension);
        final isImage = mimeType.startsWith('image/');
        final attachment = isImage
            ? await _buildImage(
                name: source.name,
                mimeType: mimeType,
                sizeBytes: size,
                bytes: bytes,
              )
            : await parser.parseAsync(
                name: source.name,
                mimeType: mimeType,
                sizeBytes: size,
                bytes: bytes,
              );
        if (!isCurrent()) return AttachmentIngestResult(cancelled: true);
        additions.add(attachment);
        runningTotal += isImage ? attachment.sizeBytes : size;
      } on FileReadLimitExceeded {
        if (readLimit < maxAttachmentBytes) {
          overTotal++;
        } else {
          tooLarge++;
        }
      } catch (_) {
        unreadable++;
      }
    }
    if (!isCurrent()) return AttachmentIngestResult(cancelled: true);
    return AttachmentIngestResult(
      attachments: additions,
      tooMany: tooMany,
      tooLarge: tooLarge,
      overTotal: overTotal,
      unreadable: unreadable,
    );
  }

  static Future<Attachment> _buildImage({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) async {
    if (bytes.lengthInBytes > FileParser.maxImageBytes) {
      return Attachment(
        name: name,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        parseError: '图片过大（超过 5MB），未附加。',
      );
    }
    final prepared = await ImageCodecUtil.prepareReferenceImage(
      bytes,
      mimeType: mimeType,
      name: name,
    );
    return Attachment(
      name: prepared.name,
      mimeType: prepared.mimeType,
      sizeBytes: prepared.bytes.lengthInBytes,
      imageBase64: base64Encode(prepared.bytes),
    );
  }

  static String mimeFor(String? ext) => switch (ext?.toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'pdf' => 'application/pdf',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'csv' => 'text/csv',
    'tsv' => 'text/tab-separated-values',
    'json' => 'application/json',
    'md' => 'text/markdown',
    'txt' => 'text/plain',
    _ => 'text/plain',
  };
}
