import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docx_to_text/docx_to_text.dart';
import 'package:excel/excel.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

import '../../data/models.dart';

class FileReadLimitExceeded implements Exception {
  const FileReadLimitExceeded(this.maxBytes);

  final int maxBytes;
}

/// A malformed or suspicious OOXML container must not be softened into an
/// editable attachment. Keeping it would bypass the local ZIP guard and hand
/// the same hostile archive to the remote document service later.
class _OfficeArchiveRejected implements Exception {
  const _OfficeArchiveRejected(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Parses uploaded files to plain text locally (no backend). Supports digital
/// (text-layer) PDF, Word .docx, Excel .xlsx and PowerPoint .pptx. Scanned/image
/// PDFs and images yield no text (would need OCR / a vision model — M6).
class FileParser {
  /// Hard cap on extracted characters per file, to protect the context window.
  /// Excess is dropped and the attachment is flagged [Attachment.truncated].
  static const int maxChars = 60000;

  /// Guard before unzipping or decoding a document. Character truncation alone
  /// is too late: a large PDF/OOXML file can already have frozen the UI or
  /// consumed significant memory by the time text is extracted.
  static const int maxFileBytes = 15 * 1024 * 1024;

  /// OOXML documents are ZIP files. Inspect the central directory before any
  /// library asks for decompressed bytes, otherwise a tiny zip bomb can exhaust
  /// the app process despite the input-file size limit.
  static const int _maxZipEntries = 2000;
  static const int _maxZipEntryBytes = 20 * 1024 * 1024;
  static const int _maxZipExpandedBytes = 50 * 1024 * 1024;

  /// Only applied when compressed size is small — real Word/XML parts often
  /// compress 50–200× when full of styles/whitespace; absolute expanded-size
  /// caps above already bound memory.
  static const int _maxZipCompressionRatio = 1000;
  static const int _zipBombCompressedThreshold = 64 * 1024;

  /// Largest image we retain for vision models. Bigger images are rejected with
  /// a note (base64 in the prompt + DB would balloon for little benefit).
  static const int maxImageBytes = 5 * 1024 * 1024;

  /// Reads a picker-provided stream without allowing an inaccurate file-size
  /// report to bypass the caller's memory budget.
  static Future<Uint8List> readBytesWithLimit(
    Stream<List<int>> stream, {
    required int maxBytes,
  }) async {
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in stream) {
      total += chunk.length;
      if (total > maxBytes) throw FileReadLimitExceeded(maxBytes);
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  /// Runs the CPU-heavy parser outside the UI isolate. The synchronous [parse]
  /// entry point stays available for small unit tests and non-UI callers.
  Future<Attachment> parseAsync({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) => Isolate.run(
    () => FileParser().parse(
      name: name,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      bytes: bytes,
    ),
  );

  /// Build an [Attachment] from raw bytes. Never throws: parse failures are
  /// captured in [Attachment.parseError] so the UI can surface them.
  Attachment parse({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) {
    final lower = name.toLowerCase();
    final base = Attachment(
      name: name,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
    );

    if (sizeBytes > maxFileBytes || bytes.lengthInBytes > maxFileBytes) {
      return base.copyWith(
        parseError:
            '文件过大（超过 ${(maxFileBytes / 1024 / 1024).toStringAsFixed(0)}MB），未解析。',
      );
    }

    if (mimeType.startsWith('image/')) {
      if (bytes.lengthInBytes > maxImageBytes) {
        return base.copyWith(parseError: '图片过大（超过 5MB），未附加。');
      }
      // Retain the image for vision-capable models; non-vision models get a
      // textual note at send time instead (see ChatController).
      return base.copyWith(imageBase64: base64Encode(bytes));
    }

    final isEditableForService =
        lower.endsWith('.xlsx') ||
        lower.endsWith('.docx') ||
        lower.endsWith('.pptx') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.csv') ||
        lower.endsWith('.tsv');
    // Keep original bytes so document-edit can round-trip even when local text
    // extraction is partial/empty. Cap retention to avoid huge DB rows.
    final retainBinary =
        isEditableForService &&
        bytes.lengthInBytes <= maxFileBytes &&
        bytes.lengthInBytes <= 10 * 1024 * 1024;
    final retainedB64 = retainBinary ? base64Encode(bytes) : null;

    try {
      String text;
      if (lower.endsWith('.pdf')) {
        text = _parsePdf(bytes);
      } else if (lower.endsWith('.docx')) {
        text = _parseDocx(bytes);
      } else if (lower.endsWith('.xlsx')) {
        text = _parseXlsx(bytes);
      } else if (lower.endsWith('.pptx')) {
        text = _parsePptx(bytes);
      } else if (lower.endsWith('.txt') ||
          lower.endsWith('.md') ||
          lower.endsWith('.csv') ||
          lower.endsWith('.tsv') ||
          lower.endsWith('.json') ||
          mimeType.startsWith('text/')) {
        text = _decodeText(bytes);
      } else {
        return base.copyWith(parseError: '不支持的文件类型：$name');
      }

      text = text.trim();
      if (text.isEmpty) {
        // Editable files may still be patched remotely. Keep binary + soft note.
        if (retainedB64 != null) {
          return base.copyWith(
            text: '（未能从文件中提取到文本，已保留原文件供改文档）',
            imageBase64: retainedB64,
            parseError: null,
          );
        }
        return base.copyWith(parseError: '未能从文件中提取到文本（可能是扫描件/图片型文档）。');
      }
      final truncated = text.length > maxChars;
      return base.copyWith(
        text: truncated ? text.substring(0, maxChars) : text,
        truncated: truncated,
        imageBase64: retainedB64,
      );
    } on _OfficeArchiveRejected catch (e) {
      return base.copyWith(parseError: '解析失败：$e');
    } catch (e) {
      // Prefer keeping the original bytes so「改文档」still works when only the
      // local text extractor failed (zip guard false-positive, exotic XML…).
      if (retainedB64 != null) {
        return base.copyWith(
          text: '（本地文本解析失败，已保留原文件供改文档）\n原因：$e',
          imageBase64: retainedB64,
          parseError: null,
        );
      }
      return base.copyWith(parseError: '解析失败：$e');
    }
  }

  String _parsePdf(Uint8List bytes) {
    final doc = PdfDocument(inputBytes: bytes);
    try {
      return PdfTextExtractor(doc).extractText();
    } finally {
      doc.dispose();
    }
  }

  String _parseDocx(Uint8List bytes) {
    final archive = _decodeSafeZip(bytes);
    // Prefer our paragraph extractor: docx_to_text ships with a debug
    // `print(document)` and is picky about some Word/WPS XML.
    final local = _extractDocxTextFromArchive(archive).trim();
    if (local.isNotEmpty) return local;
    try {
      return docxToText(bytes).trim();
    } catch (_) {
      return local;
    }
  }

  /// Lightweight fallback: paragraph-wise `w:t` extraction from document.xml.
  String _extractDocxTextFromArchive(Archive archive) {
    final out = StringBuffer();
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');
      if (name != 'word/document.xml' && !name.endsWith('/document.xml')) {
        continue;
      }
      try {
        final content = file.content as List<int>;
        final doc = XmlDocument.parse(
          utf8.decode(content, allowMalformed: true),
        );
        for (final p in doc.findAllElements('w:p')) {
          final line = p.findAllElements('w:t').map((e) => e.innerText).join();
          if (line.trim().isNotEmpty) out.writeln(line);
        }
        if (out.isEmpty) {
          for (final t in doc.findAllElements('w:t')) {
            final s = t.innerText;
            if (s.isNotEmpty) out.write(s);
          }
        }
      } catch (_) {
        continue;
      }
    }
    return out.toString();
  }

  String _parseXlsx(Uint8List bytes) {
    _decodeSafeZip(bytes);
    final excel = Excel.decodeBytes(bytes);
    final out = StringBuffer();
    for (final entry in excel.tables.entries) {
      out.writeln('# ${entry.key}');
      for (final row in entry.value.rows) {
        final cells = row
            .map((c) => c?.value == null ? '' : c!.value.toString())
            .toList();
        // Skip fully empty rows.
        if (cells.every((c) => c.isEmpty)) continue;
        out.writeln(cells.join('\t'));
      }
      out.writeln();
    }
    return out.toString();
  }

  String _parsePptx(Uint8List bytes) {
    final archive = _decodeSafeZip(bytes);
    // Slides are ppt/slides/slideN.xml; order them numerically.
    final slides =
        archive.files
            .where(
              (f) =>
                  f.isFile &&
                  f.name.startsWith('ppt/slides/slide') &&
                  f.name.endsWith('.xml'),
            )
            .toList()
          ..sort((a, b) => _slideIndex(a.name).compareTo(_slideIndex(b.name)));

    final out = StringBuffer();
    for (final slide in slides) {
      try {
        final content = slide.content as List<int>;
        final doc = XmlDocument.parse(
          utf8.decode(content, allowMalformed: true),
        );
        // <a:t> elements hold the visible text runs.
        final texts = doc
            .findAllElements('a:t')
            .map((e) => e.innerText)
            .where((t) => t.trim().isNotEmpty);
        if (texts.isNotEmpty) out.writeln(texts.join(' '));
      } catch (_) {
        // Skip a single corrupt/unparsable slide rather than failing the whole
        // deck — the rest of the presentation is still worth extracting.
        continue;
      }
    }
    return out.toString();
  }

  Archive _decodeSafeZip(Uint8List bytes) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw _OfficeArchiveRejected(
        '不是有效的 Office 压缩包（.docx/.xlsx/.pptx）。'
        '若是旧版 .doc/.xls/.ppt，请先另存为新格式。原始错误：$e',
      );
    }
    if (archive.files.length > _maxZipEntries) {
      throw const _OfficeArchiveRejected('压缩文档包含过多条目，已拒绝解析。');
    }

    var expandedBytes = 0;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final declaredSize = file.size;
      // Directory markers and zero-byte parts are normal in OOXML packages.
      if (declaredSize <= 0) continue;
      if (declaredSize > _maxZipEntryBytes) {
        throw const _OfficeArchiveRejected('压缩文档含有过大的文件条目，已拒绝解析。');
      }
      expandedBytes += declaredSize;
      if (expandedBytes > _maxZipExpandedBytes) {
        throw const _OfficeArchiveRejected('压缩文档解压后内容过大，已拒绝解析。');
      }

      // rawContent may be absent after some archive versions finish decoding;
      // prefer content length when available rather than hard-failing.
      final compressedSize = file.rawContent?.length ?? 0;
      if (compressedSize > 0 &&
          compressedSize < _zipBombCompressedThreshold &&
          declaredSize / compressedSize > _maxZipCompressionRatio) {
        throw const _OfficeArchiveRejected('压缩文档压缩比异常，已拒绝解析。');
      }
    }
    return archive;
  }

  int _slideIndex(String path) {
    final match = RegExp(r'slide(\d+)\.xml').firstMatch(path);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  String _decodeText(Uint8List bytes) {
    try {
      return utf8.decode(bytes); // strict: succeeds only for real UTF-8
    } catch (_) {
      // Not valid UTF-8. Decode leniently and check how much was unmappable: a
      // high proportion of replacement chars means a legacy encoding (e.g. GBK
      // /GB2312, common on Chinese Windows) we can't read — surface a clear
      // error instead of silently feeding the model garbage (the old latin1
      // fallback never threw, so mojibake slipped through unnoticed).
      final lenient = utf8.decode(bytes, allowMalformed: true);
      final replacements = '�'.allMatches(lenient).length;
      if (lenient.isNotEmpty && replacements / lenient.length > 0.1) {
        throw const FormatException(
          '文件不是 UTF-8 编码（可能是 GBK/GB2312 等），无法可靠解析；请另存为 UTF-8 后重试。',
        );
      }
      return lenient;
    }
  }
}
