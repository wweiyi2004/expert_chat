import 'package:expert_chat/domain/chat/markdown_blocks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty and single paragraph stay one block', () {
    expect(splitMarkdownBlocks(''), isEmpty);
    expect(splitMarkdownBlocks('hello world'), ['hello world']);
    expect(splitMarkdownBlocks('hello\nworld'), ['hello\nworld']);
  });

  test('headings and blank lines start new blocks', () {
    expect(splitMarkdownBlocks('# Title\n\nFirst paragraph.\n\nSecond.'), [
      '# Title',
      'First paragraph.',
      'Second.',
    ]);
  });

  test('fenced code keeps inner blank lines in one block', () {
    const md = '# Title\n\n```python\ndef foo():\n\n    return 1\n```\n\nAfter';
    expect(splitMarkdownBlocks(md), [
      '# Title',
      '```python\ndef foo():\n\n    return 1\n```',
      'After',
    ]);
  });

  test('unclosed fence stays the last block', () {
    const md = 'Intro\n\n```js\nconst x = 1;\n';
    expect(splitMarkdownBlocks(md), ['Intro', '```js\nconst x = 1;']);
  });

  test('tight and loose lists stay one block', () {
    expect(splitMarkdownBlocks('- a\n- b\n- c'), ['- a\n- b\n- c']);
    expect(splitMarkdownBlocks('1. a\n\n2. b\n\n3. c'), [
      '1. a\n\n2. b\n\n3. c',
    ]);
  });

  test('math blocks stay together', () {
    expect(splitMarkdownBlocks('Before\n\n\$\$\na + b\n\$\$\n\nAfter'), [
      'Before',
      '\$\$\na + b\n\$\$',
      'After',
    ]);
  });

  test('display math with blank lines stays one block', () {
    expect(
      splitMarkdownBlocks('Before\n\n\$\$\n\na_i + b_i\n\n\$\$\n\nAfter'),
      ['Before', '\$\$\n\na_i + b_i\n\n\$\$', 'After'],
    );
    expect(splitMarkdownBlocks('Before\n\n\\[\n\na_i\n\n\\]\n\nAfter'), [
      'Before',
      '\\[\n\na_i\n\n\\]',
      'After',
    ]);
    expect(
      splitMarkdownBlocks(
        'Before\n\n\\begin{align}\n\na &= b \\\\\n\n\\end{align}\n\nAfter',
      ),
      ['Before', '\\begin{align}\n\na &= b \\\\\n\n\\end{align}', 'After'],
    );
  });

  test('unclosed display math swallows following lines', () {
    expect(splitMarkdownBlocks('Intro\n\n\$\$\nE = mc^2\n'), [
      'Intro',
      '\$\$\nE = mc^2',
    ]);
  });

  test('completed blocks stay stable while appending', () {
    const prefix = '# Title\n\nFirst paragraph.\n\n';
    final frozen = splitMarkdownBlocks('${prefix}S');
    expect(frozen.take(2).toList(), ['# Title', 'First paragraph.']);

    var text = prefix;
    for (final rune in 'Second paragraph continues.'.runes) {
      text += String.fromCharCode(rune);
      final blocks = splitMarkdownBlocks(text);
      expect(blocks[0], frozen[0]);
      expect(blocks[1], frozen[1]);
      expect(blocks.last, startsWith('S'));
    }
  });

  test('closing a fence freezes it when more text arrives', () {
    const open = '```dart\nvoid main() {}\n```';
    final before = splitMarkdownBlocks(open);
    expect(before, [open]);
    final after = splitMarkdownBlocks('$open\n\nDone.');
    expect(after.first, open);
    expect(after.last, 'Done.');
  });

  group('StreamingMarkdownDocument', () {
    test(
      'character chunks finalize to the same blocks as one-shot parsing',
      () {
        const samples = <String>[
          '# Title\n\nFirst paragraph.\n\nSecond **bold** paragraph.',
          '- one\n\n- two\n\n- three\n\nAfter',
          'Before\n\n```dart\nvoid main() {}\n```\n\nAfter',
          'Before\n\n\$\$\na_i + b_i\n\$\$\n\nAfter',
          '> quote one\n> quote two\n\nAfter',
          '| A | B |\n| --- | --- |\n| 1 | 2 |',
        ];

        for (final sample in samples) {
          final document = StreamingMarkdownDocument();
          var snapshot = '';
          for (final rune in sample.runes) {
            snapshot += String.fromCharCode(rune);
            document.updateSnapshot(snapshot, isFinal: false);
          }
          document.updateSnapshot(snapshot, isFinal: true);
          expect(
            document.blocks.map((block) => block.source).toList(),
            splitMarkdownBlocks(sample),
            reason: sample,
          );
          expect(document.pendingBlock, isNull, reason: sample);
          expect(document.blocks, everyElement(isA<StreamingMarkdownBlock>()));
          expect(
            document.blocks,
            everyElement(
              predicate<StreamingMarkdownBlock>((block) => block.isStable),
            ),
          );
        }
      },
    );

    test('completed blocks retain object identity and pending block id', () {
      final document = StreamingMarkdownDocument();
      document.updateSnapshot(
        '# Title\n\nFirst paragraph.\n\nSec',
        isFinal: false,
      );

      final title = document.blocks[0];
      final first = document.blocks[1];
      final pendingId = document.pendingBlock!.id;
      final pendingRevision = document.pendingBlock!.revision;

      document.updateSnapshot(
        '# Title\n\nFirst paragraph.\n\nSecond paragraph.',
        isFinal: false,
      );

      expect(identical(document.blocks[0], title), isTrue);
      expect(identical(document.blocks[1], first), isTrue);
      expect(document.pendingBlock!.id, pendingId);
      expect(document.pendingBlock!.revision, greaterThan(pendingRevision));
      expect(document.pendingBlock!.source, 'Second paragraph.');
    });

    test('only the unfinished tail is rescanned after a stable prefix', () {
      final prefix = '${List.filled(50000, 'a').join()}\n\n';
      final document = StreamingMarkdownDocument();
      document.updateSnapshot('${prefix}tail', isFinal: false);
      expect(document.lastParsedCharacters, greaterThan(50000));

      document.updateSnapshot(
        '${prefix}tail!',
        isFinal: false,
        assumeAppendOnly: true,
      );

      expect(document.lastParsedCharacters, 'tail!'.length);
      expect(document.stableBlocks.single.source.length, 50000);
      expect(document.pendingBlock!.source, 'tail!');
    });

    test('append-only normalization handles CRLF split across chunks', () {
      const source = '# Title\r\n\r\nFirst\r\n\r\nSecond';
      final document = StreamingMarkdownDocument();
      var snapshot = '';
      for (final unit in source.codeUnits) {
        snapshot += String.fromCharCode(unit);
        document.updateSnapshot(
          snapshot,
          isFinal: false,
          assumeAppendOnly: true,
        );
      }
      document.updateSnapshot(snapshot, isFinal: true, assumeAppendOnly: true);

      expect(document.content, '# Title\n\nFirst\n\nSecond');
      expect(document.blocks.map((block) => block.source), [
        '# Title',
        'First',
        'Second',
      ]);
    });

    test('non-append snapshots reset safely', () {
      final document = StreamingMarkdownDocument();
      document.updateSnapshot('Old\n\nTail', isFinal: false);
      final resetsBefore = document.resetCount;

      final update = document.updateSnapshot('# Replacement', isFinal: false);

      expect(update, MarkdownSnapshotUpdate.reset);
      expect(document.resetCount, resetsBefore + 1);
      expect(document.blocks.map((block) => block.source), ['# Replacement']);
      expect(document.blocks.single.id, 0);
    });

    test('finalization promotes an unclosed tail without changing its id', () {
      final document = StreamingMarkdownDocument();
      document.updateSnapshot('```dart\nvoid main() {', isFinal: false);
      final id = document.pendingBlock!.id;
      expect(document.context.openFenceMarker, '```');
      expect(document.pendingBlock!.isStable, isFalse);

      final update = document.updateSnapshot(
        '```dart\nvoid main() {',
        isFinal: true,
      );

      expect(update, MarkdownSnapshotUpdate.finalized);
      expect(document.pendingBlock, isNull);
      expect(document.blocks.single.id, id);
      expect(document.blocks.single.isStable, isTrue);
      expect(document.context.hasPendingSyntax, isFalse);
    });

    test('loose lists stay pending until their continuation is known', () {
      final document = StreamingMarkdownDocument();
      document.updateSnapshot('- one\n\n', isFinal: false);
      final id = document.pendingBlock!.id;
      expect(document.context.awaitingListContinuation, isTrue);

      document.updateSnapshot('- one\n\n- two', isFinal: false);
      expect(document.pendingBlock!.id, id);
      expect(document.pendingBlock!.source, '- one\n\n- two');
      expect(document.stableBlocks, isEmpty);

      document.updateSnapshot('- one\n\n- two\n\nAfter', isFinal: false);
      expect(document.stableBlocks.single.id, id);
      expect(document.stableBlocks.single.source, '- one\n\n- two');
      expect(document.pendingBlock!.source, 'After');
    });

    test('reports incomplete inline and math contexts', () {
      final document = StreamingMarkdownDocument();
      document.updateSnapshot(
        'Text with **bold and [link](target and `code',
        isFinal: false,
      );
      expect(document.context.hasUnclosedStrong, isTrue);
      expect(document.context.hasUnclosedInlineCode, isTrue);
      expect(document.context.hasUnclosedLink, isTrue);

      document.updateSnapshot('Before\n\n\$\$\na + b', isFinal: false);
      expect(document.context.hasUnclosedMath, isTrue);
      expect(document.context.blockType, StreamingMarkdownBlockType.math);
    });

    test('classifies common block types', () {
      final blocks = StreamingMarkdownDocument()
        ..updateSnapshot(
          '# H\n\n- item\n\n> quote\n\n'
          '| A | B |\n| --- | --- |\n| 1 | 2 |\n\n'
          '<section>html</section>',
          isFinal: true,
        );

      expect(blocks.blocks.map((block) => block.type), [
        StreamingMarkdownBlockType.heading,
        StreamingMarkdownBlockType.list,
        StreamingMarkdownBlockType.blockQuote,
        StreamingMarkdownBlockType.table,
        StreamingMarkdownBlockType.html,
      ]);
    });
  });
}
