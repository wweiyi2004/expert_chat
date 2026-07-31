import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'html_preview_launcher_policy.dart';

export 'html_preview_launcher_policy.dart'
    show PreviewUrlPolicy, previewUrlPolicy;

bool _unloadRevokerInstalled = false;

/// Opens a sandboxed HTML document from a user gesture on Web.
///
/// A blob URL avoids unsupported `dart:io` temporary files and the browser
/// restrictions around top-level `data:` navigations.
Future<void> launchHtmlPreview(String html, {required String fileName}) async {
  final policy = previewUrlPolicy;
  if (policy.needsNewUrlFor(html)) {
    final blob = web.Blob(
      <web.BlobPart>[html.toJS].toJS,
      web.BlobPropertyBag(type: 'text/html;charset=utf-8'),
    );
    policy.register(html, web.URL.createObjectURL(blob));
  }
  final anchor = web.HTMLAnchorElement()
    ..href = policy.url!
    ..target = '_blank'
    ..rel = 'noopener noreferrer';
  anchor.click();
  _installUnloadRevoker();
}

void _installUnloadRevoker() {
  if (_unloadRevokerInstalled) return;
  _unloadRevokerInstalled = true;
  // Object URLs must outlive the new tab's fetch, which browsers delay for
  // background tabs — the old fixed 1-minute timer could revoke them
  // mid-load. Revoke only when this window goes away; the next preview then
  // mints a fresh URL (revoke() is idempotent, so pagehide + unload both
  // firing is harmless).
  web.window.addEventListener(
    'pagehide',
    ((web.Event _) => previewUrlPolicy.revoke()).toJS,
  );
  web.window.addEventListener(
    'unload',
    ((web.Event _) => previewUrlPolicy.revoke()).toJS,
  );
}
