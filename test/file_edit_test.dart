import 'package:expert_chat/domain/desktop/file_edit.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _edit(String old, String replacement, {bool? all}) => {
  'old_string': old,
  'new_string': replacement,
  'replace_all': ?all,
};

void main() {
  test('edits apply in order and replace_all covers every occurrence', () {
    expect(
      applyFileEdits('a b a', [
        _edit('a b', 'x b'),
        _edit('a', 'z'),
        _edit('b', 'B', all: true),
      ]),
      'x B z',
    );
  });

  test('missing, ambiguous, empty and no-op edits are rejected', () {
    Matcher fails(String text) => throwsA(
      isA<FileEditException>().having(
        (e) => e.message,
        'message',
        contains(text),
      ),
    );
    expect(() => applyFileEdits('abc', [_edit('zzz', 'y')]), fails('找不到'));
    expect(() => applyFileEdits('aa', [_edit('a', 'b')]), fails('出现 2 次'));
    expect(() => applyFileEdits('abc', [_edit('', 'y')]), fails('不能为空'));
    expect(() => applyFileEdits('abc', [_edit('a', 'a')]), fails('相同'));
    expect(() => applyFileEdits('abc', []), fails('非空数组'));
    expect(
      () => applyFileEdits('abc', [
        {'old_string': 1},
      ]),
      fails('字符串'),
    );
    expect(
      () => applyFileEdits('abc', [_edit('ab', 'x'), _edit('ab', 'y')]),
      fails('第 2 处修改'),
    );
  });

  test('LF snippets match CRLF files and keep CRLF line endings', () {
    expect(
      applyFileEdits('one\r\ntwo\r\nthree\r\n', [
        _edit('one\ntwo', 'ONE\nTWO\nextra'),
      ]),
      'ONE\r\nTWO\r\nextra\r\nthree\r\n',
    );
  });

  test('edit tool is offered only when read and write are both available', () {
    const read = ToolSpec(
      name: 'coding_read_file',
      description: '',
      parameters: {},
    );
    const write = ToolSpec(
      name: 'coding_write_file',
      description: '',
      parameters: {},
    );
    expect(
      withFileEdit([read]).map((t) => t.name),
      isNot(contains(fileEditToolName)),
    );
    final tools = withFileEdit(withFileEdit([read, write]));
    expect(tools.where((t) => t.name == fileEditToolName), hasLength(1));
  });
}
