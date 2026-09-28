import 'dart:io';

import 'package:expert_chat/domain/html/html_snippet.dart';
import 'package:expert_chat/features/chat/widgets/html_preview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:webview_windows/webview_windows.dart' as windows;

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows renders local HTML/SVG, executes inline JS and blocks remote requests',
    (tester) async {
      final folder = await Directory.systemTemp.createTemp(
        'expert-chat-code-preview-',
      );
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(folder.path);
      addTearDown(() => PathProviderPlatform.instance = originalPaths);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) {
        requests++;
        request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final html =
          '''<html><head><style>button{background:rgb(12,34,56)}</style></head><body>
<button id="run" onclick="this.textContent='clicked'">ready</button>
<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="30" fill="red"/></svg>
<script>
let blocked = false;
fetch('http://127.0.0.1:${server.port}/blocked').catch(() => blocked = true);
window.addEventListener('message', event => {
  if(event.data === 'exercise') document.querySelector('button').click();
});
setInterval(() => {
 let isolated = false;
 try { void parent.document.body; } catch (_) { isolated = true; }
 parent.postMessage({localPreview:true, text:document.querySelector('button').textContent,
 color:getComputedStyle(document.querySelector('button')).backgroundColor,
 svg:document.querySelector('circle').getBBox().width, blocked, isolated}, '*');
}, 80);
</script></body></html>''';
      await tester.pumpWidget(
        MaterialApp(
          home: HtmlPreviewPage(
            snippets: [previewSnippetForCode('html', html)!],
          ),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (find.byType(windows.Webview).evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(windows.Webview), findsOneWidget);
      final controller = tester
          .widget<windows.Webview>(find.byType(windows.Webview))
          .controller;
      Map<dynamic, dynamic>? result;
      Object? lastReport;
      while (DateTime.now().isBefore(deadline)) {
        await controller.executeScript(
          "if (!window.previewListening) { window.previewListening = true; window.addEventListener('message', e => { if(e.data && e.data.localPreview) window.previewResult = e.data; }); }"
          "document.querySelector('iframe')?.contentWindow.postMessage('exercise','*');",
        );
        final value = await controller.executeScript(
          'window.previewResult || null',
        );
        lastReport = value;
        if (value is Map &&
            value['text'] == 'clicked' &&
            value['blocked'] == true) {
          result = value;
          break;
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
      final host = await controller.executeScript(
        "({url:location.href, ready:document.readyState, frame:!!document.querySelector('iframe'), listening:window.previewListening})",
      );
      expect(result, isNotNull, reason: 'host=$host, report=$lastReport');
      expect(result!['color'], 'rgb(12, 34, 56)');
      expect(result['svg'], 60);
      expect(result['isolated'], isTrue);
      expect(requests, 0);
      await tester.tap(find.text('源码'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(windows.Webview), findsNothing);
      await tester.tap(find.byKey(const ValueKey('preview-run')));
      while (find.byType(windows.Webview).evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(windows.Webview), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isWindows,
  );
}
