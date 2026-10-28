import 'dart:typed_data';
import 'package:syncfusion_flutter_pdf/pdf.dart';

String extractPdfText(Uint8List bytes) {
  final doc = PdfDocument(inputBytes: bytes);
  try {
    return PdfTextExtractor(doc).extractText();
  } finally {
    doc.dispose();
  }
}
