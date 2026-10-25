import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Browser render session; the document already contains the isolated preview.
class LocalHtmlSurface extends StatefulWidget {
  const LocalHtmlSurface({super.key, required this.document, this.zoom});
  final double? zoom;
  final String document;

  @override
  State<LocalHtmlSurface> createState() => _LocalHtmlSurfaceState();
}

class _LocalHtmlSurfaceState extends State<LocalHtmlSurface> {
  web.HTMLIFrameElement? _frame;
  void _zoom() => _frame?.contentWindow?.postMessage(
    {'type': 'expert-preview-scale', 'zoom': widget.zoom}.jsify(),
    '*'.toJS,
  );
  @override
  void didUpdateWidget(covariant LocalHtmlSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoom != widget.zoom) _zoom();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'iframe',
    onElementCreated: (element) {
      final frame = element as web.HTMLIFrameElement;
      _frame = frame;
      frame.addEventListener('load', ((web.Event _) => _zoom()).toJS);
      frame
        ..title = 'HTML / SVG 本地预览'
        ..setAttribute('sandbox', 'allow-scripts')
        ..referrerPolicy = 'no-referrer'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.border = '0'
        ..style.display = 'block'
        ..srcdoc = widget.document.toJS;
    },
  );
}
