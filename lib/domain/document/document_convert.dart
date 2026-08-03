import 'document_patch.dart';

/// Cross-format conversion matrix shared by App validation and LLM tool docs.
///
/// Must stay in sync with `server/doc_edit/app/main.py` (`CONVERSIONS`).
class DocumentConvert {
  DocumentConvert._();

  static const supportedFormats = DocumentPatch.supportedFormats;

  /// Source format → allowed targets (includes same-format re-encode).
  static const Map<String, Set<String>> conversions = {
    'txt': {'txt', 'md', 'docx', 'csv', 'tsv'},
    'md': {'md', 'txt', 'docx'},
    'csv': {'csv', 'tsv', 'txt', 'md', 'xlsx'},
    'tsv': {'tsv', 'csv', 'txt', 'md', 'xlsx'},
    'xlsx': {'xlsx', 'csv', 'tsv', 'txt', 'md'},
    'docx': {'docx', 'txt', 'md'},
    'pptx': {'pptx', 'txt', 'md'},
  };

  static bool canConvert(String from, String to) {
    final src = from.toLowerCase().trim();
    final tgt = to.toLowerCase().trim();
    return conversions[src]?.contains(tgt) ?? false;
  }

  static Set<String> targetsFor(String from) =>
      Set<String>.unmodifiable(conversions[from.toLowerCase().trim()] ?? const {});

  static String matrixSummary() {
    final buf = StringBuffer();
    for (final e in conversions.entries) {
      if (buf.isNotEmpty) buf.write('；');
      buf.write('${e.key}→${e.value.join("/")}');
    }
    return buf.toString();
  }
}
