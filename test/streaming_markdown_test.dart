import 'package:expert_chat/features/chat/widgets/streaming_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

void main() {
  testWidgets('keeps stable block keys while the tail grows and finalizes', (
    tester,
  ) async {
    Future<void> pump(String content, {required bool isFinal}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StreamingGptMarkdown(
                content,
                key: const ValueKey('streaming-markdown'),
                isFinal: isFinal,
              ),
            ),
          ),
        );

    await pump('# Title\n\nTai', isFinal: false);
    expect(find.byType(GptMarkdown), findsNWidgets(2));
    expect(find.byKey(const ValueKey(0)), findsOneWidget);
    expect(find.byKey(const ValueKey(1)), findsOneWidget);

    await pump('# Title\n\nTail grows', isFinal: false);
    expect(find.byType(GptMarkdown), findsNWidgets(2));
    expect(find.byKey(const ValueKey(0)), findsOneWidget);
    expect(find.byKey(const ValueKey(1)), findsOneWidget);

    await pump('# Title\n\nTail grows', isFinal: true);
    expect(find.byType(GptMarkdown), findsNWidgets(2));
    expect(find.byKey(const ValueKey(0)), findsOneWidget);
    expect(find.byKey(const ValueKey(1)), findsOneWidget);
  });

  testWidgets('resets the incremental document for replacement content', (
    tester,
  ) async {
    Future<void> pump(String content) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamingGptMarkdown(
            content,
            key: const ValueKey('streaming-markdown'),
            isFinal: false,
          ),
        ),
      ),
    );

    await pump('# Old\n\nTail');
    expect(find.byType(GptMarkdown), findsNWidgets(2));

    await pump('Replacement');
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.byKey(const ValueKey(0)), findsOneWidget);
    expect(find.byKey(const ValueKey(1)), findsNothing);
  });

  testWidgets('preserves open and closed code-fence semantics', (tester) async {
    Future<void> pump(String content, {required bool isFinal}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StreamingGptMarkdown(
                content,
                key: const ValueKey('streaming-markdown'),
                isFinal: isFinal,
                codeBuilder: (context, name, code, closed) =>
                    Text(closed ? 'fence-closed' : 'fence-open'),
              ),
            ),
          ),
        );

    await pump('```html\n<div>', isFinal: false);
    expect(find.text('fence-open'), findsOneWidget);

    await pump('```html\n<div>\n```', isFinal: false);
    expect(find.text('fence-closed'), findsOneWidget);

    await pump('```html\n<div>\n```', isFinal: true);
    expect(find.text('fence-closed'), findsOneWidget);
  });
}
