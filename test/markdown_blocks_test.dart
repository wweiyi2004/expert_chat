import 'package:expert_chat/domain/chat/markdown_blocks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty and single paragraph stay one block', () {
    expect(splitMarkdownBlocks(''), isEmpty);
    expect(splitMarkdownBlocks('hello world'), ['hello world']);
    expect(splitMarkdownBlocks('hello\nworld'), ['hello\nworld']);
  });

  test('headings and blank lines start new blocks', () {
    expect(
      splitMarkdownBlocks('# Title\n\nFirst paragraph.\n\nSecond.'),
      ['# Title', 'First paragraph.', 'Second.'],
    );
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
    expect(splitMarkdownBlocks('1. a\n\n2. b\n\n3. c'), ['1. a\n\n2. b\n\n3. c']);
  });

  test('math blocks stay together', () {
    expect(
      splitMarkdownBlocks('Before\n\n\$\$\na + b\n\$\$\n\nAfter'),
      ['Before', '\$\$\na + b\n\$\$', 'After'],
    );
  });

  test('display math with blank lines stays one block', () {
    expect(
      splitMarkdownBlocks('Before\n\n\$\$\n\na_i + b_i\n\n\$\$\n\nAfter'),
      ['Before', '\$\$\n\na_i + b_i\n\n\$\$', 'After'],
    );
    expect(
      splitMarkdownBlocks('Before\n\n\\[\n\na_i\n\n\\]\n\nAfter'),
      ['Before', '\\[\n\na_i\n\n\\]', 'After'],
    );
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
}
