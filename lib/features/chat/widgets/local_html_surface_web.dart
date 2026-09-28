import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Browser render session; the document already contains the isolated preview.
class LocalHtmlSurface extends StatelessWidget {
  const LocalHtmlSurface({super.key, required this.document});
  final String document;

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'iframe',
    onElementCreated: (element) {
      final frame = element as web.HTMLIFrameElement;
      frame
        ..title = 'HTML / SVG 本地预览'
        ..setAttribute('sandbox', 'allow-scripts')
        ..referrerPolicy = 'no-referrer'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.border = '0'
        ..style.display = 'block'
        ..srcdoc = document.toJS;
    },
  );
}
