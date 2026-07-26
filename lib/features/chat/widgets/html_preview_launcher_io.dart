import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a sandboxed HTML document in the platform browser on native targets.
///
/// [forceAndroid] exists for tests only — the Android refusal below cannot be
/// exercised from a desktop test runner otherwise.
Future<void> launchHtmlPreview(
  String html, {
  required String fileName,
  @visibleForTesting bool? forceAndroid,
}) async {
  if (forceAndroid ?? Platform.isAndroid) {
    // ACTION_VIEW with a file:// URI throws FileUriExposedException on
    // Android 7+, and data: URIs overflow the Binder transaction for real
    // pages. This path is only reached when the WebView component is missing;
    // steer the user to the copy-HTML action instead of failing obscurely.
    throw StateError('此设备无法在外部浏览器中打开本地预览，请使用“复制 HTML”后在浏览器中查看。');
  }
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsString(html, encoding: utf8);
  final ok = await launchUrl(
    Uri.file(file.path),
    mode: LaunchMode.externalApplication,
  );
  if (!ok) throw StateError('无法打开系统浏览器预览');
}
