import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/tui_bridge/snapshot_evidence.dart';
import 'package:expert_chat/state/work_approvals.dart';
import 'package:expert_chat/state/work_changes.dart';
import 'package:flutter_test/flutter_test.dart';

String hash(String text) => sha256.convert(utf8.encode(text)).toString();
final started = DateTime.utc(2020, 1, 1);
SearchActivity read(
  String content, {
  String path = 'file.txt',
  String scope = 'root',
  String? receiptHash,
  String? encoding,
}) => SearchActivity(
  id: 'read',
  kind: SearchActivityKind.mcp,
  query: path,
  toolName: 'coding_read_file',
  status: SearchActivityStatus.done,
  startedAt: started,
  finishedAt: started.add(const Duration(seconds: 1)),
  toolArguments: jsonEncode({
    'path': path,
    'scope': scope,
    if (encoding != null) 'encoding': encoding,
  }),
  resultText: jsonEncode({
    'path': path,
    'scope': scope,
    'content': content,
    'sha256': receiptHash ?? hash(content),
  }),
);
SearchActivity write(
  String id,
  String before,
  String after,
  int second, {
  bool fresh = false,
}) => SearchActivity(
  id: id,
  kind: SearchActivityKind.mcp,
  query: 'file.txt',
  toolName: 'coding_write_file',
  status: SearchActivityStatus.done,
  startedAt: started.add(Duration(seconds: second)),
  finishedAt: started.add(Duration(seconds: second + 1)),
  toolArguments: jsonEncode({
    'path': 'file.txt',
    'scope': 'root',
    'content': after,
    'expected_sha256': fresh ? 'new' : hash(before),
  }),
  resultText: jsonEncode({
    'path': 'file.txt',
    'scope': 'root',
    'sha256': hash(after),
  }),
);
PendingWorkApproval approval(
  String before,
  String after, {
  String conversation = 'c',
  String path = 'file.txt',
  String scope = 'root',
  bool fresh = false,
}) => PendingWorkApproval(
  id: 'approval',
  conversationId: conversation,
  tool: 'coding_write_file',
  target: 'fixed authorized target',
  reason: '',
  arguments: jsonEncode({
    'path': path,
    'scope': scope,
    'content': after,
    'expected_sha256': fresh ? 'new' : hash(before),
  }),
);
TuiSnapshotEvidence evidence(
  List<SearchActivity> activities, {
  List<WorkFileChange> changes = const [],
}) => TuiSnapshotEvidence(
  conversationId: 'c',
  messages: [
    ChatMessage(
      id: 'm',
      role: MessageRole.assistant,
      content: '',
      searchActivities: activities,
    ),
  ],
  changes: changes,
);

void main() {
  test(
    'proposed overwrite diff uses exact completed read receipt with verified content hash',
    () {
      final result = evidence([
        read('old\n'),
      ]).approvalDiff(approval('old\n', 'new\n'));
      expect(result, containsAll(['-old', '+new']));
      expect(result.first, contains('执行前仍核验'));
    },
  );
  test(
    'new file preview is explicitly conditional and needs no disk access',
    () {
      final result = evidence(
        [],
      ).approvalDiff(approval('', 'new\n', fresh: true));
      expect(result, contains('+new'));
      expect(result.first, contains('拟新建'));
    },
  );
  test(
    'mismatched hash, path, scope, binary receipt and another conversation never fake a diff',
    () {
      final request = approval('old\n', 'new\n');
      for (final source in [
        read('different\n'),
        read('old\n', path: 'other.txt'),
        read('old\n', scope: 'other'),
        read('forged\n', receiptHash: hash('old\n')),
        read('old\n', encoding: 'base64'),
      ]) {
        final result = evidence([source]).approvalDiff(request);
        expect(result.single, startsWith('无法预览'));
        expect(result, isNot(contains('-old')));
      }
      expect(
        evidence([
          read('old\n'),
        ]).approvalDiff(approval('old\n', 'new\n', conversation: 'other')),
        isEmpty,
      );
    },
  );
  test(
    'successful exact write maps counts from verified same-assistant before snapshot',
    () {
      final step = write('write', 'old\n', 'new\nextra\n', 2);
      final change = WorkFileChange(
        id: 'change',
        conversationId: 'c',
        assistantId: 'm',
        target: 'target',
        scope: 'root',
        path: 'file.txt',
        before: 'old\n',
        after: 'new\nextra\n',
        beforeHash: hash('old\n'),
        afterHash: hash('new\nextra\n'),
        updatedAt: started.add(const Duration(seconds: 3)),
      );
      expect(evidence([step], changes: [change]).stepLineCounts('m', step), {
        'added': 2,
        'removed': 1,
      });
      expect(
        evidence([step], changes: [change]).stepLineCounts('other', step),
        {'added': null, 'removed': null},
      );
    },
  );
  test(
    'merged WorkChange does not copy aggregate line totals to every write step',
    () {
      final first = write('first', 'old\n', 'middle\n', 2);
      final second = write('second', 'middle\n', 'new\nextra\n', 4);
      final change = WorkFileChange(
        id: 'merged',
        conversationId: 'c',
        assistantId: 'm',
        target: 'target',
        scope: 'root',
        path: 'file.txt',
        before: 'old\n',
        after: 'new\nextra\n',
        beforeHash: hash('old\n'),
        afterHash: hash('new\nextra\n'),
        updatedAt: started.add(const Duration(seconds: 5)),
      );
      final snapshot = evidence([first, second], changes: [change]);
      expect(snapshot.stepLineCounts('m', first), {'added': 1, 'removed': 1});
      expect(snapshot.stepLineCounts('m', second), {'added': 2, 'removed': 1});
    },
  );
  test('unverified or absent before content keeps step counts unknown', () {
    final step = write('write', 'old\n', 'new\n', 2);
    expect(evidence([]).stepLineCounts('m', step), {
      'added': null,
      'removed': null,
    });
    final bad = step.copyWith(
      resultText: jsonEncode({
        'path': 'file.txt',
        'scope': 'root',
        'sha256': hash('forged'),
      }),
    );
    expect(evidence([read('old\n')]).stepLineCounts('m', bad), {
      'added': null,
      'removed': null,
    });
  });
}
