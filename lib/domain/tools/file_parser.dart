import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docx_to_text/docx_to_text.dart';
import 'package:excel/excel.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

import '../../data/models.dart';

/// Parses uploaded files to plain text locally (no backend). Supports digital
/// (text-layer) PDF, Word .docx, Excel .xlsx and PowerPoint .pptx. Scanned/image
/// PDFs and images yield no text (would need OCR / a vision model — M6).
class FileParser {
  /// Hard cap on extracted characters per file, to protect the context window.
  /// Excess is dropped and the attachment is flagged [Attachment.truncated].
  static const int maxChars = 60000;

  /// Largest image we retain for vision models. Bigger images are rejected with
  /// a note (base64 in the prompt + DB would balloon for little benefit).
  static const int maxImageBytes = 5 * 1024 * 1024;

  /// Build an [Attachment] from raw bytes. Never throws: parse failures are
  /// captured in [Attachment.parseError] so the UI can surface them.
  Attachment parse({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) {
    final lower = name.toLowerCase();
    final base = Attachment(name: name, mimeType: mimeType, sizeBytes: sizeBytes);

    if (mimeType.startsWith('image/')) {
      if (bytes.lengthInBytes > maxImageBytes) {
        return base.copyWith(
          parseError: '图片过大（超过 5MB），未附加。',
        );
      }
      // Retain the image for vision-capable models; non-vision models get a
      // textual note at send time instead (see ChatController).
      return base.copyWith(imageBase64: base64Encode(bytes));
    }

    try {
      String text;
      if (lower.endsWith('.pdf')) {
        text = _parsePdf(bytes);
      } else if (lower.endsWith('.docx')) {
        text = docxToText(bytes);
      } else if (lower.endsWith('.xlsx')) {
        text = _parseXlsx(bytes);
      } else if (lower.endsWith('.pptx')) {
        text = _parsePptx(bytes);
      } else if (lower.endsWith('.txt') ||
          lower.endsWith('.md') ||
          lower.endsWith('.csv') ||
          lower.endsWith('.json') ||
          mimeType.startsWith('text/')) {
        text = _decodeText(bytes);
      } else {
        return base.copyWith(parseError: '不支持的文件类型：$name');
      }

      text = text.trim();
      if (text.isEmpty) {
        return base.copyWith(
          parseError: '未能从文件中提取到文本（可能是扫描件/图片型文档）。',
        );
      }
      final truncated = text.length > maxChars;
      return base.copyWith(
        text: truncated ? text.substring(0, maxChars) : text,
        truncated: truncated,
      );
    } catch (e) {
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

  String _parseXlsx(Uint8List bytes) {
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
    final archive = ZipDecoder().decodeBytes(bytes);
    // Slides are ppt/slides/slideN.xml; order them numerically.
    final slides = archive.files
        .where((f) =>
            f.isFile &&
            f.name.startsWith('ppt/slides/slide') &&
            f.name.endsWith('.xml'))
        .toList()
      ..sort((a, b) => _slideIndex(a.name).compareTo(_slideIndex(b.name)));

    final out = StringBuffer();
    for (final slide in slides) {
      final content = slide.content as List<int>;
      final doc = XmlDocument.parse(utf8.decode(content));
      // <a:t> elements hold the visible text runs.
      final texts =
          doc.findAllElements('a:t').map((e) => e.innerText).where((t) => t.trim().isNotEmpty);
      if (texts.isNotEmpty) out.writeln(texts.join(' '));
    }
    return out.toString();
  }

  int _slideIndex(String path) {
    final match = RegExp(r'slide(\d+)\.xml').firstMatch(path);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  String _decodeText(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }
}
