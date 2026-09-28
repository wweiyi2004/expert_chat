@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:expert_chat/domain/html/html_snippet.dart';
import 'package:expert_chat/features/chat/widgets/html_preview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  // Live frames attach platform-view DOM nodes to the browser document.
  LiveTestWidgetsFlutterBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  testWidgets(
    'browser preview resizes the real CSS viewport without reloading',
    (tester) async {
      // Browser widget tests normally discard platform messages, including the
      // iframe creation request. Keep test fonts, but use real platform views.
      final environment = ui_web.TestEnvironment.instance;
      ui_web.TestEnvironment.setUp(
        const ui_web.TestEnvironment(
          forceTestFonts: true,
          disableFontFallbacks: true,
          keepSemanticsDisabledOnUpdate: true,
          defaultToTestUrlStrategy: true,
        ),
      );
      addTearDown(() => ui_web.TestEnvironment.setUp(environment));
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<Object?, Object?>? report;
      final listener = ((web.Event event) {
        final value = (event as web.MessageEvent).data.dartify();
        if (value is Map && value['responsivePreview'] == true) report = value;
      }).toJS;
      web.window.addEventListener('message', listener);
      addTearDown(() => web.window.removeEventListener('message', listener));
      const source = '''<!doctype html><html><head><style>
html,body{margin:0}.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}
@media(max-width:430px){.grid{grid-template-columns:1fr}}
</style></head><body><div class="grid"><p>one</p><p>two</p></div>
<script>
const session = Math.random();
setInterval(() => {
 let isolated = false;
 try { void parent.parent.document.body; } catch (_) { isolated = true; }
 parent.parent.postMessage({responsivePreview:true, width:innerWidth,
   narrow:matchMedia('(max-width:430px)').matches,
   columns:getComputedStyle(document.querySelector('.grid')).gridTemplateColumns,
   overflow:document.documentElement.scrollWidth > innerWidth, session, isolated}, '*');
}, 40);
</script></body></html>''';
      await tester.pumpWidget(
        MaterialApp(
          home: HtmlPreviewPage(
            snippets: [previewSnippetForCode('html', source)!],
          ),
        ),
      );

      Future<void> waitFor(bool Function(Map<Object?, Object?>) matches) async {
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          if (report != null && matches(report!)) return;
        }
        fail('Missing expected DOM report: $report');
      }

      await waitFor((r) => (r['width'] as num) > 430);
      expect(report!['narrow'], isFalse);
      expect(report!['isolated'], isTrue);
      expect((report!['columns'] as String).split(' '), hasLength(2));
      final session = report!['session'];
      await tester.tap(find.byKey(const ValueKey('preview-phone-width')));
      await waitFor((r) => r['width'] == 390);
      for (final width in [360, 430]) {
        await tester.tap(find.byKey(const ValueKey('preview-device-width')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('$width px').last);
        await waitFor((r) => r['width'] == width);
        expect(report!['narrow'], isTrue);
        expect(report!['overflow'], isFalse);
        expect((report!['columns'] as String).split(' '), hasLength(1));
        expect(report!['session'], session);
      }
      await tester.tap(find.byKey(const ValueKey('preview-phone-width')));
      await waitFor((r) => (r['width'] as num) > 430);
      expect(report!['narrow'], isFalse);
      expect(report!['session'], session);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
