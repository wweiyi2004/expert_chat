import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Opens a sandboxed HTML document from a user gesture on Web.
///
/// A blob URL avoids unsupported `dart:io` temporary files and the browser
/// restrictions around top-level `data:` navigations.
Future<void> launchHtmlPreview(String html, {required String fileName}) async {
  final blob = web.Blob(
    <web.BlobPart>[html.toJS].toJS,
    web.BlobPropertyBag(type: 'text/html;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..target = '_blank'
    ..rel = 'noopener noreferrer';
  anchor.click();

  // Keep the object URL alive long enough for a newly opened tab to load it.
  Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
}
