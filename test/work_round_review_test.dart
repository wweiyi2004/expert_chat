import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/workbench/changes/line_diff.dart';
import 'package:expert_chat/domain/workbench/changes/work_file_change.dart';

void main() {
  test(
    'separate changed blocks can be reverted without reverting accepted block',
    () {
      const before = 'first\nkeep\nsecond\n';
      const after = 'FIRST\nkeep\nSECOND\n';
      expect(changedDiffBlocks(before, after), hasLength(2));
      expect(revertDiffBlocks(before, after, {0}), 'first\nkeep\nSECOND\n');
      expect(revertDiffBlocks(before, after, {1}), 'FIRST\nkeep\nsecond\n');
      expect(revertDiffBlocks(before, after, {0, 1}), before);
    },
  );
  test(
    'partial rollback preserves untouched mixed line terminators byte for byte',
    () {
      const before = 'a\r\nb\nc\r\nd\n';
      const after = 'A\r\nb\nC\r\nd\n';
      expect(revertDiffBlocks(before, after, {0}), 'a\r\nb\nC\r\nd\n');
      expect(revertDiffBlocks(before, after, {1}), 'A\r\nb\nc\r\nd\n');
    },
  );
  test('all chunks restore exact CRLF and final-newline semantics', () {
    const before = 'old\r\nkeep';
    const after = 'new\r\nkeep\r\n';
    expect(revertDiffBlocks(before, after, {0}), before);
  });
  test('round and large directory metadata survive copy and persistence', () {
    final file = WorkFileChange(
      id: 'c',
      conversationId: 'conversation',
      target: 'root',
      scope: 'root',
      path: 'dist',
      before: null,
      after: '',
      beforeHash: null,
      afterHash: 'v2',
      updatedAt: DateTime(2026),
      roundId: 'request2',
      beforeKnown: false,
      artifactManifest: {
        'kind': 'directory',
        'bytes': 99999999,
        'entries': [
          {'path': 'dist/file.bin', 'sha256': 'v2'},
        ],
      },
    );
    final restored = WorkFileChange.fromJson(file.withDelivery(true).toJson());
    expect(restored.roundId, 'request2');
    expect(restored.artifactManifest!['kind'], 'directory');
    expect(restored.withDelivery(false).artifactManifest!['bytes'], 99999999);
    expect(restored.canRestore, isFalse);
  });
}
