import 'package:expert_chat/domain/html/html_preview_sandbox.dart';
import 'package:expert_chat/domain/html/html_snippet.dart';
import 'package:expert_chat/features/chat/widgets/previewable_code_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
