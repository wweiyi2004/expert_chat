import 'package:expert_chat/domain/html/html_preview_sandbox.dart';
import 'package:expert_chat/domain/html/html_snippet.dart';
import 'package:expert_chat/features/chat/widgets/previewable_code_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildSandboxedHtmlPreview policy injection', () {
    String srcdocOf(String out) => out.substring(out.indexOf('srcdoc="'));

    test('lands in the real head, not a commented-out one', () {
      final out = buildSandboxedHtmlPreview(
        '<!-- <head> -->'
        '<html><head><title>t</title></head><body>hi</body></html>',
      );

      final srcdoc = srcdocOf(out);
      final commentEnd = srcdoc.indexOf('--&gt;');
      final policyPos = srcdoc.indexOf('Content-Security-Policy');
      expect(commentEnd, greaterThan(-1));
      expect(policyPos, greaterThan(commentEnd));
    });

    test('ignores a <head> inside a script string literal', () {
      final out = buildSandboxedHtmlPreview(
        '<script>var x = "<head>";</script>'
        '<html><head><title>t</title></head></html>',
      );

      final srcdoc = srcdocOf(out);
      final scriptEnd = srcdoc.lastIndexOf('&lt;/script&gt;');
      final realHead = srcdoc.lastIndexOf('&lt;head&gt;');
      final policyPos = srcdoc.indexOf('Content-Security-Policy');
      expect(scriptEnd, greaterThan(-1));
      // The meta must not be swallowed into the string literal...
      expect(policyPos, greaterThan(scriptEnd));
      // ...and must land inside the real head, not the fake one.
      expect(policyPos, greaterThan(realHead));
    });

    test('ignores a <head> inside a tag attribute value', () {
      final out = buildSandboxedHtmlPreview(
        '<div data-x="<head>">'
        '<html><head><title>t</title></head></html>',
      );

      final srcdoc = srcdocOf(out);
      final realHead = srcdoc.lastIndexOf('&lt;head&gt;');
      final policyPos = srcdoc.indexOf('Content-Security-Policy');
      expect(realHead, greaterThan(-1));
      expect(policyPos, greaterThan(realHead));
    });

    test('ignores a <head> inside style element content', () {
      final out = buildSandboxedHtmlPreview(
        '<style>/* <head> */</style>'
        '<html><head><title>t</title></head></html>',
      );

      final srcdoc = srcdocOf(out);
      final styleEnd = srcdoc.lastIndexOf('&lt;/style&gt;');
      final realHead = srcdoc.lastIndexOf('&lt;head&gt;');
      final policyPos = srcdoc.indexOf('Content-Security-Policy');
      expect(styleEnd, greaterThan(-1));
      expect(policyPos, greaterThan(styleEnd));
      expect(policyPos, greaterThan(realHead));
    });

    test('bare fragment with a fake <head> still gets a policy head', () {
      final out = buildSandboxedHtmlPreview(
        '<script>const t = "<head>";</script><p>hi</p>',
      );

      final srcdoc = srcdocOf(out);
      final scriptStart = srcdoc.indexOf('&lt;script&gt;');
      final policyPos = srcdoc.indexOf('Content-Security-Policy');
      expect(scriptStart, greaterThan(-1));
      expect(srcdoc, contains('&lt;p&gt;hi&lt;/p&gt;'));
      // No real head exists, so the wrapper head must carry the policy,
      // placed before any executable content.
      expect(policyPos, lessThan(scriptStart));
    });

    test('does not treat a <head> inside the body as an injection point', () {
      final out = buildSandboxedHtmlPreview(
        '<body><p><head></p></body>',
      );

      final srcdoc = srcdocOf(out);
      final fakeHead = srcdoc.lastIndexOf('&lt;head&gt;');
      final policyPos = srcdoc.indexOf('Content-Security-Policy');
      expect(fakeHead, greaterThan(-1));
      // There is no real head, so the wrapper head must carry the policy,
      // placed before any document content — never inside the body-level
      // fake <head>, where a CSP meta would be inert.
      expect(policyPos, lessThan(fakeHead));
    });

    test('keeps injecting into a normal single head (regression)', () {
      final out = buildSandboxedHtmlPreview(
        '<HTML><HEAD><TITLE>t</TITLE></HEAD><BODY>x</BODY></HTML>',
      );

      final srcdoc = srcdocOf(out).toLowerCase();
      final headPos = srcdoc.indexOf('&lt;head&gt;');
      final titlePos = srcdoc.indexOf('&lt;title&gt;');
      final policyPos = srcdoc.indexOf('content-security-policy');
      expect(headPos, greaterThan(-1));
      expect(policyPos, greaterThan(headPos));
      expect(policyPos, lessThan(titlePos));
    });
  });

  group('extractHtmlSnippets', () {
    test('extracts fenced html blocks', () {
      const md = '''
这是一个页面：

```html
<!DOCTYPE html>
<html><head><title>Hello</title></head>
<body><h1>Hi</h1></body></html>
```
''';
      final snips = extractHtmlSnippets(md);
      expect(snips, hasLength(1));
      expect(snips.first.title, 'Hello');
      expect(snips.first.html.toLowerCase(), contains('<h1>hi</h1>'));
    });

    test('wraps html fragments', () {
      const md = '''
```html
<div class="card"><button>Go</button></div>
<style>.card{padding:8px}</style>
```
''';
      final snips = extractHtmlSnippets(md);
      expect(snips, hasLength(1));
      expect(snips.first.html.toLowerCase(), contains('<!doctype html>'));
      expect(snips.first.html, contains('class="card"'));
    });

    test('ignores non-html fences', () {
      const md = '''
```dart
void main() {}
```
''';
      expect(extractHtmlSnippets(md), isEmpty);
    });

    test('ignores unlabeled plain-text and source-code fences', () {
      expect(extractHtmlSnippets('```\njust some plain text\n```'), isEmpty);
      expect(
        extractHtmlSnippets('```\nvoid main() => print("hi");\n```'),
        isEmpty,
      );
    });

    test('detects bare full documents', () {
      const raw = '''
<!DOCTYPE html>
<html><body><p>ok</p></body></html>
''';
      final snips = extractHtmlSnippets(raw);
      expect(snips, hasLength(1));
      expect(messageHasHtmlPreview(raw), isTrue);
    });
  });

  test(
    'sandbox blocks network capabilities while retaining inline scripts',
    () {
      const raw = '''
<!DOCTYPE html>
<html><head><title>Demo</title></head>
<body><script>document.body.dataset.ready = "yes";</script></body></html>
''';
      final preview = buildSandboxedHtmlPreview(raw);
      expect(preview, contains('sandbox="allow-scripts"'));
      expect(preview, contains("connect-src 'none'"));
      expect(preview, contains("frame-src 'none'"));
      // `srcdoc` inherits the host CSP, so the host must not accidentally
      // tighten away capabilities which the inner policy intentionally allows.
      expect(
        htmlPreviewHostContentSecurityPolicy,
        contains("script-src 'unsafe-inline'"),
      );
      expect(
        htmlPreviewHostContentSecurityPolicy,
        contains('img-src data: blob:'),
      );
      expect(
        htmlPreviewHostContentSecurityPolicy,
        contains("frame-src 'self'"),
      );
      expect(preview, contains('&lt;script&gt;'));
      expect(preview, isNot(contains('allow-same-origin')));
      expect(preview, isNot(contains('allow-popups')));
    },
  );

  testWidgets('only HTML code blocks expose the preview action', (
    tester,
  ) async {
    Future<void> pump(String name, String code) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewableCodeBlock(name: name, code: code),
        ),
      ),
    );

    await pump('dart', 'void main() {}');
    expect(find.text('预览'), findsNothing);

    await pump('', 'plain text');
    expect(find.text('预览'), findsNothing);

    await pump('html', '<main><button>Go</button></main>');
    expect(find.text('预览'), findsOneWidget);
  });
}
