import 'dart:convert';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/state/work_memory.dart';
import 'package:expert_chat/state/work_operation_journal.dart';

void main() {
  test(
    'memory survives restart, isolates identity and rejects stale updates',
    () async {
      String? disk;
      WorkMemory open() => WorkMemory(
        read: () => disk,
        write: (s) async {
          disk = s;
          return true;
        },
      );
      final first = open();
      await first.checkpoint('one', {
        'expected_revision': 0,
        'constraints': 'Never overwrite user edits',
        'plan': 'verify artifact v2',
        'summary': 'tool 17 completed',
      });
      expect(
        open().snapshot('one')['constraints'],
        contains('Never overwrite'),
      );
      expect(open().snapshot('two'), isEmpty);
      await expectLater(
        first.checkpoint('one', {'expected_revision': 0, 'summary': 'stale'}),
        throwsStateError,
      );
      expect(first.snapshot('one')['summary'], 'tool 17 completed');
    },
  );
  test(
    'write-ahead persistence precedes effect and duplicate call never repeats',
    () async {
      String? disk;
      var effects = 0;
      final journal = WorkOperationJournal(
        read: () => disk,
        write: (s) async {
          disk = s;
          return true;
        },
      );
      Future<String> run() => journal.run(
        conversation: 'c',
        task: 't',
        callId: 'call',
        tool: 'send',
        arguments: 'secret',
        operation: () async {
          expect(
            (jsonDecode(disk!) as Map)['entries'].single['status'],
            'started',
          );
          effects++;
          return 'secret result';
        },
      );
      await run();
      expect(jsonDecode(await run())['already_dispatched'], isTrue);
      expect(effects, 1);
      expect(disk, isNot(contains('secret')));
    },
  );
  test(
    'restart unknown blocks a new call until deliberate acknowledgment',
    () async {
      String? disk = jsonEncode([
        {
          'conversation': 'c',
          'task': 't',
          'call_id': 'old',
          'tool': 'send',
          'status': 'started',
        },
      ]);
      var effects = 0;
      final journal = WorkOperationJournal(
        read: () => disk,
        write: (s) async {
          disk = s;
          return true;
        },
      );
      Future<String> run() => journal.run(
        conversation: 'c',
        task: 't',
        callId: 'new',
        tool: 'send',
        arguments: '{}',
        operation: () async {
          effects++;
          return 'done';
        },
      );
      expect(jsonDecode(await run())['requires_user_resume'], isTrue);
      expect(effects, 0);
      await journal.acknowledge(
        'c',
        reviewedIdentities: journal
            .unresolved('c')
            .map((e) => e['review_identity'] as String)
            .toSet(),
      );
      expect(await run(), 'done');
      expect(effects, 1);
    },
  );
  test(
    'persistence failure prevents effect and thrown side effect stays unknown',
    () async {
      var effects = 0;
      final failing = WorkOperationJournal(
        read: () => null,
        write: (s) async => false,
      );
      await expectLater(
        failing.run(
          conversation: 'c',
          task: 't',
          callId: 'x',
          tool: 'send',
          arguments: '{}',
          operation: () async {
            effects++;
            return 'done';
          },
        ),
        throwsStateError,
      );
      expect(effects, 0);
      String? disk;
      final journal = WorkOperationJournal(
        read: () => disk,
        write: (s) async {
          disk = s;
          return true;
        },
      );
      await expectLater(
        journal.run(
          conversation: 'c',
          task: 't',
          callId: 'x',
          tool: 'send',
          arguments: '{}',
          operation: () async {
            throw StateError('disconnect');
          },
        ),
        throwsStateError,
      );
      expect(journal.unresolved('c'), hasLength(1));
    },
  );
  test(
    'failed memory save does not publish a revision; concurrent CAS remains atomic',
    () async {
      var writes = 0;
      String? disk;
      final memory = WorkMemory(
        read: () => disk,
        write: (s) async {
          writes++;
          if (writes == 1) return false;
          disk = s;
          return true;
        },
      );
      await expectLater(
        memory.checkpoint('a', {
          'expected_revision': 0,
          'summary': 'not saved',
        }),
        throwsStateError,
      );
      expect(memory.snapshot('a'), isEmpty);
      final results = await Future.wait([
        memory
            .checkpoint('a', {'expected_revision': 0, 'summary': 'committed'})
            .then<Object>((v) => v, onError: (Object e) => e),
        memory
            .checkpoint('a', {'expected_revision': 0, 'summary': 'stale'})
            .then<Object>((v) => v, onError: (Object e) => e),
        memory
            .checkpoint('b', {'expected_revision': 0, 'summary': 'separate'})
            .then<Object>((v) => v, onError: (Object e) => e),
      ]);
      expect(results[1], isA<StateError>());
      expect(memory.snapshot('a')['summary'], 'committed');
      expect(
        WorkMemory(
          read: () => disk,
          write: (s) async => true,
        ).snapshot('b')['summary'],
        'separate',
      );
    },
  );
  test(
    'two agents and request identities can reuse provider call IDs',
    () async {
      String? disk;
      var effects = 0;
      final journal = WorkOperationJournal(
        read: () => disk,
        write: (s) async {
          disk = s;
          return true;
        },
      );
      Future<String> run(String agent, String request) => journal.run(
        conversation: 'c',
        task: 't',
        callId: 'call_0',
        agent: agent,
        request: request,
        tool: 'write',
        arguments: '{}',
        operation: () async {
          effects++;
          return 'done';
        },
      );
      await Future.wait([
        run('childA', 'r1'),
        run('childB', 'r1'),
        run('childA', 'r2'),
      ]);
      await run('childA', 'r1');
      expect(effects, 3);
    },
  );
  test(
    'returned uncertain outcome blocks effect replay, corrupt bytes survive acknowledgment',
    () async {
      String? disk;
      final journal = WorkOperationJournal(
        read: () => disk,
        write: (s) async {
          disk = s;
          return true;
        },
      );
      await journal.run(
        conversation: 'c',
        task: 't',
        callId: 'x',
        tool: 'command',
        arguments: '{}',
        classify: (_) => WorkOperationOutcome.unknown,
        operation: () async => 'cancelled remotely',
      );
      expect(journal.unresolved('c'), hasLength(1));
      final corrupt = WorkOperationJournal(
        read: () => '{bad bytes',
        write: (s) async {
          disk = s;
          return true;
        },
      );
      await corrupt.acknowledge(
        'c',
        reviewedIdentities: {},
        reviewedCorruptionDigest: corrupt.corruptionDigest,
      );
      expect(jsonDecode(disk!)['corrupt_backup'], '{bad bytes');
    },
  );
  test(
    'history pages original tool results and excludes private reasoning',
    () {
      final message = ChatMessage(
        role: MessageRole.assistant,
        content: 'public',
        reasoning: 'private',
        searchActivities: [
          SearchActivity(
            id: 'tool1',
            kind: SearchActivityKind.mcp,
            query: 'read',
            toolName: 'read',
            resultText: List.filled(13000, 'x').join(),
          ),
        ],
      );
      final result = WorkMemory.history(
        [message],
        {'source_id': 'tool1', 'content_offset': 6000},
      );
      final page = (result['messages'] as List).single as Map;
      expect(page['content'], hasLength(6000));
      expect(page['next_content_offset'], 12000);
      expect(jsonEncode(result), isNot(contains('private')));
    },
  );
  test(
    'compaction preserves pinned constraints and protocol tool pairs',
    () async {
      final memory = WorkMemory(read: () => null, write: (s) async => true);
      await memory.checkpoint('c', {
        'expected_revision': 0,
        'summary': 'work completed',
        'constraints': 'KEEP THIS EXACT CONSTRAINT',
        'compact': true,
      });
      final history = [
        const LlmRequestMessage(role: MessageRole.system, content: 'persona'),
        for (var i = 0; i < 20; i++)
          LlmRequestMessage(role: MessageRole.user, content: 'older $i'),
        const LlmRequestMessage(
          role: MessageRole.user,
          content: 'current task',
        ),
      ];
      final result = memory.manage(
        'c',
        history,
        const ContextPrefs(
          contextWindowTokens: 8192,
          reservedOutputTokens: 1024,
        ),
        compact: true,
      );
      expect(
        result.messages.first.content,
        contains('KEEP THIS EXACT CONSTRAINT'),
      );
      expect(result.messages.any((m) => m.content == 'current task'), isTrue);
      expect(result.report.droppedMessages, greaterThan(0));
      expect(history, hasLength(22));
    },
  );

  test('model memory updates cannot overwrite user pins', () async {
    final memory = WorkMemory(read: () => null, write: (s) async => true);
    await memory.checkpoint('c', {
      'expected_revision': 0,
      'user_pins': 'User hard constraint',
    }, userInitiated: true);
    await memory.checkpoint('c', {
      'expected_revision': 1,
      'user_pins': 'model replacement',
      'summary': 'updated',
    });
    expect(memory.snapshot('c')['user_pins'], 'User hard constraint');
  });
  test(
    'agent memory CAS scopes cannot overwrite root plan or sibling scope',
    () async {
      String? disk;
      final memory = WorkMemory(
        read: () => disk,
        write: (s) async {
          disk = s;
          return true;
        },
      );
      await memory.checkpoint('c', {
        'expected_revision': 0,
        'plan': 'root plan',
        'user_pins': 'user immutable constraint',
      }, userInitiated: true);
      await Future.wait([
        memory.checkpoint('c', {
          'expected_revision': 0,
          'plan': 'child A plan',
          'summary': 'A result',
          'user_pins': 'attempted overwrite',
        }, agentId: 'A'),
        memory.checkpoint('c', {
          'expected_revision': 0,
          'plan': 'child B plan',
          'summary': 'B result',
        }, agentId: 'B'),
      ]);
      expect(memory.snapshot('c')['plan'], 'root plan');
      expect(memory.snapshot('c')['user_pins'], 'user immutable constraint');
      expect(memory.snapshot('c', agentId: 'A')['plan'], 'child A plan');
      expect(memory.snapshot('c', agentId: 'B')['plan'], 'child B plan');
      expect(
        memory.snapshot('c', agentId: 'A').containsKey('user_pins'),
        isFalse,
      );
      expect(
        memory.guidance('c', agentId: 'A'),
        contains('read_only_root_handoff'),
      );
      final restored = WorkMemory(read: () => disk, write: (s) async => true);
      expect(restored.snapshot('c', agentId: 'B')['summary'], 'B result');
    },
  );
  test(
    'acknowledgment applies only to identities actually displayed, not new unknown records',
    () async {
      String? disk = jsonEncode([
        {
          'identity': 'first',
          'conversation': 'c',
          'task': 't',
          'call_id': '1',
          'tool': 'send',
          'status': 'unknown',
        },
      ]);
      final journal = WorkOperationJournal(
        read: () => disk,
        write: (s) async {
          disk = s;
          return true;
        },
      );
      final reviewed = journal
          .unresolved('c')
          .map((e) => e['review_identity'] as String)
          .toSet();
      journal.entries.add({
        'identity': 'second',
        'conversation': 'c',
        'task': 't',
        'call_id': '2',
        'tool': 'send',
        'status': 'unknown',
      });
      await journal.acknowledge('c', reviewedIdentities: reviewed);
      expect(journal.unresolved('c').single['identity'], 'second');
      final corrupt = WorkOperationJournal(
        read: () => '{broken',
        write: (s) async => true,
      );
      await expectLater(
        corrupt.acknowledge('c', reviewedIdentities: {}),
        throwsStateError,
      );
      expect(corrupt.corrupt, isTrue);
    },
  );
  test(
    'corrupt fixed memory fails closed and repair preserves exact reviewed source before publication',
    () async {
      String? saved, archive;
      final memory = WorkMemory(
        read: () => '{bad memory',
        write: (s) async {
          saved = s;
          return true;
        },
        archiveCorrupt: (s) async {
          archive = s;
          return true;
        },
      );
      expect(() => memory.guidance('c'), throwsStateError);
      await expectLater(
        memory.checkpoint('c', {
          'expected_revision': 0,
          'summary': 'ignore corruption',
        }),
        throwsStateError,
      );
      await expectLater(
        memory.repairCorrupt('c', 'wrong-source', 'pins'),
        throwsStateError,
      );
      await memory.repairCorrupt(
        'c',
        memory.corruptDigest!,
        'reviewed constraints',
      );
      expect(archive, '{bad memory');
      expect(memory.snapshot('c')['user_pins'], 'reviewed constraints');
      expect(memory.corrupt, isFalse);
      expect(jsonDecode(saved!)['c']['user_pins'], 'reviewed constraints');
    },
  );
}
