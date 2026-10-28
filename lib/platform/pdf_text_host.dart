import 'dart:convert';
import 'dart:typed_data';
import 'media_worker.dart';

String extractPdfText(Uint8List bytes) =>
    runMediaWorker({'op': 'pdf_text', 'data': base64Encode(bytes)})['text']
        as String;
