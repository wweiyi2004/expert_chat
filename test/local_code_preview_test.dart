import 'package:expert_chat/domain/html/html_snippet.dart';
import 'package:expert_chat/features/chat/widgets/html_preview_page.dart';
import 'package:expert_chat/features/chat/widgets/previewable_code_block.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const svg =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><title>圆形</title><circle cx="50" cy="50" r="40" fill="blue"/></svg>';
  const html = '<button onclick="this.textContent=42">开始</button>';

  test(
    'full documents gain a viewport while source and authored viewport survive',
    () {
      const raw =
          '<!doctype html><html><head><!-- <meta name="viewport"> -->'
          '<script>const sample = "<meta name=viewport>";</script></head><body>ok</body></html>';
      final snippet = previewSnippetForCode('html', raw)!;
      expect(snippet.code, raw);
      final document = html_parser.parse(snippet.html);
      expect(
        document.head!
            .querySelector('meta[name=viewport]')!
            .attributes['content'],
        'width=device-width, initial-scale=1',
      );
      expect(document.querySelector('script')!.text, contains('const sample'));
      const authored =
          '<html><head><meta NAME="viewport" content="width=800"></head><body>ok</body></html>';
      expect(previewSnippetForCode('html', authored)!.html, authored);
    },
  );

  test('fixed pixel SVG dimensions get a scalable coordinate system', () {
    const raw =
        '<svg width="1200px" height="600"><rect width="1200" height="600"/></svg>';
    final snippet = previewSnippetForCode('svg', raw)!;
    expect(snippet.code, raw);
    expect(snippet.html, contains('viewBox="0 0 1200.0 600.0"'));
    expect(
      previewSnippetForCode('svg', svg)!.html,
      contains('viewBox="0 0 100 100"'),
    );
    expect(
      previewSnippetForCode('svg', '<svg width="100%" height="600"/>')!.html,
      isNot(contains('viewBox=')),
    );
  });

  test(
    'SVG fences and XML declarations retain editable source and SVG rendering',
    () {
      final source = '<?xml version="1.0"?>\n$svg';
      for (final language in [
        'svg',
        'xml',
        'image/svg+xml',
        'diagram.svg',
        '',
      ]) {
        final snippet = previewSnippetForCode(language, source)!;
        expect(snippet.kind, HtmlPreviewKind.svg);
        expect(snippet.code, source);
        expect(snippet.title, '圆形');
        expect(snippet.html, contains('<svg'));
        expect(snippet.html, isNot(contains('<?xml')));
      }
      expect(extractHtmlSnippets(svg).single.kind, HtmlPreviewKind.svg);
    },
  );

  test('multiple fences preserve order and deduplicate identical snippets', () {
    final snippets = extractHtmlSnippets(
      '```html\n$html\n```\n```svg\n$svg\n```\n```svg\n$svg\n```',
    );
    expect(snippets.map((s) => s.kind), [
      HtmlPreviewKind.html,
      HtmlPreviewKind.svg,
    ]);
    expect(extractHtmlSnippets('~~~svg\n$svg\n~~~').single.code, svg);
    expect(
      previewSnippetForCode('xml', '<data><value>42</value></data>'),
      isNull,
    );
    expect(previewSnippetForCode('javascript', 'const a = "$html";'), isNull);
  });

  test('unfinished fences never become raw HTML previews', () {
    expect(
      extractHtmlSnippets('```html\n<!DOCTYPE html><html><body>partial'),
      isEmpty,
    );
    expect(extractHtmlSnippets('```svg\n$svg'), isEmpty);
    expect(previewSnippetForCode('svg', '<svg><circle'), isNull);
    expect(
      previewSnippetForCode('html', '<input placeholder="hello">'),
      isNotNull,
    );
    expect(
      extractHtmlSnippets(
        '````html\n<pre>```</pre><p>ok</p>\n````',
      ).single.code,
      contains('```'),
    );
  });

  testWidgets('SVG code blocks expose preview only when complete', (
    tester,
  ) async {
    Future<void> pump(bool closed) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewableCodeBlock(name: 'svg', code: svg, closed: closed),
        ),
      ),
    );
    await pump(false);
    expect(find.byKey(const ValueKey('code-local-preview')), findsNothing);
    await pump(true);
    expect(find.byKey(const ValueKey('code-local-preview')), findsOneWidget);
  });

  Future<void> page(
    WidgetTester tester, {
    bool multi = false,
    double width = 1000,
  }) async {
    tester.view.physicalSize = Size(width, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: HtmlPreviewPage(
          snippets: [
            previewSnippetForCode('html', html)!,
            if (multi) previewSnippetForCode('svg', svg)!,
          ],
          surfaceBuilder: (_, document) => Text(
            document,
            key: const ValueKey('rendered-document'),
            maxLines: 2,
          ),
        ),
      ),
    );
  }

  testWidgets(
    'editing updates only preview after run and copying keeps original source',
    (tester) async {
      await page(tester);
      final rendered = tester
          .widget<Text>(find.byKey(const ValueKey('rendered-document')))
          .data!;
      expect(rendered, contains('sandbox="allow-scripts"'));
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byTooltip('复制源码'));
      await tester.pump();
      expect(copied, html);
      await tester.tap(find.text('源码'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('preview-source')),
        '<h1>修改后的页面</h1>',
      );
      await tester.tap(find.byKey(const ValueKey('preview-run')));
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('rendered-document')))
            .data,
        contains('修改后的页面'),
      );
      expect(html, contains('开始'));
    },
  );

  testWidgets(
    'invalid source stays editable without replacing the rendered document',
    (tester) async {
      await page(tester);
      await tester.tap(find.text('源码'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('preview-source')),
        'plain text',
      );
      await tester.tap(find.byKey(const ValueKey('preview-run')));
      await tester.pump();
      expect(find.text('请填写有效的 HTML 或完整的 SVG 代码。'), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-source')), findsOneWidget);
    },
  );

  testWidgets('switching snippets preserves separate drafts', (tester) async {
    await page(tester, multi: true);
    await tester.tap(find.text('源码'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('preview-source')),
      '<p>草稿</p>',
    );
    await tester.tap(find.byTooltip('下一页'));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('preview-source')))
          .controller!
          .text,
      svg,
    );
    await tester.tap(find.byTooltip('上一页'));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('preview-source')))
          .controller!
          .text,
      '<p>草稿</p>',
    );
  });

  for (final width in [320.0, 1000.0]) {
    testWidgets('preview toolbar and mobile viewport fit width $width', (
      tester,
    ) async {
      await page(tester, multi: true, width: width);
      if (width >= 600) {
        await tester.tap(find.byKey(const ValueKey('preview-phone-width')));
      } else {
        expect(find.byKey(const ValueKey('preview-phone-width')), findsNothing);
      }
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const ValueKey('rendered-document'))).width,
        lessThanOrEqualTo(390),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'narrow preview keeps source editor above keyboard and safe area',
    (tester) async {
      await page(tester, width: 360);
      tester.view.padding = FakeViewPadding(bottom: 24);
      tester.view.viewPadding = FakeViewPadding(bottom: 24);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await tester.pump();
      final surface = tester.getRect(
        find.byKey(const ValueKey('rendered-document')),
      );
      expect(surface.width, 360);
      expect(surface.top, lessThan(135));
      expect(surface.bottom, lessThanOrEqualTo(696));
      await tester.tap(find.text('源码'));
      tester.view.viewInsets = FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final editor = tester.getRect(
        find.byKey(const ValueKey('preview-source')),
      );
      expect(editor.height, greaterThan(180));
      expect(editor.bottom, lessThanOrEqualTo(440));
      expect(
        find.byKey(const ValueKey('preview-run')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
