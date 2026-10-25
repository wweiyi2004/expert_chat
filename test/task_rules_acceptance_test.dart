import 'package:expert_chat/domain/workbench/agents/repository_context_reader.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/state/task_acceptance_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/task_core/task_acceptance_io.dart';
import 'package:expert_chat/domain/workbench/agents/repository_context_io.dart';

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.empty();
  @override
  Future<bool> setValue(String type, String key, Object value) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'corrupt acceptance storage preserves raw bytes and blocks every mutation',
    () async {
      const broken = '{"tasks":[{"taskId":"root","criteria":false}]}';
      SharedPreferences.setMockInitialValues({
        TaskAcceptanceStore.storageKey: broken,
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final store = container.read(taskAcceptanceProvider.notifier);
      expect(store.storageError, isNotNull);
      expect(store.rawStoredValue, broken);
      expect(() => store.requireFrozen('root'), throwsStateError);
      await expectLater(
        store.freeze('root', AcceptanceCriteria()),
        throwsStateError,
      );
      await expectLater(
        store.saveDraft('c', AcceptanceCriteria()),
        throwsStateError,
      );
      await expectLater(
        store.update('root', (task) => task.replyComplete = true),
        throwsStateError,
      );
      expect(prefs.getString(TaskAcceptanceStore.storageKey), broken);
    },
  );
  test('missing frozen root cannot resume with default criteria', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final store = container.read(taskAcceptanceProvider.notifier);
    expect(store.storageError, isNull);
    expect(() => store.requireFrozen('old-root'), throwsStateError);
    await expectLater(
      store.freeze('old-root', AcceptanceCriteria(), requireExisting: true),
      throwsStateError,
    );
    expect(container.read(taskAcceptanceProvider), isEmpty);
    await store.freeze(
      'new-root',
      AcceptanceCriteria(description: 'user defined'),
    );
    expect(() => store.requireFrozen('new-root'), returnsNormally);
  });

  test(
    'authorized reader loads SSH scoped rules and named skills, rechecks every read',
    () async {
      final data = <String, String>{
        'AGENTS.md': 'root remote',
        'CLAUDE.md': 'compatible remote',
        'a/AGENTS.md': 'a remote',
        'b/AGENTS.md': 'b remote',
        '.agents/skills/review/SKILL.md':
            '---\nname: review\ndescription: review metadata\n---\nselected body',
      };
      var revoked = false, reads = 0;
      Future<List<RepositoryEntry>?> list(String path) async {
        final prefix = path == '.' ? '' : '$path/';
        final children = <String, RepositoryEntry>{};
        for (final entry in data.entries) {
          if (!entry.key.startsWith(prefix)) {
            continue;
          }
          final tail = entry.key.substring(prefix.length);
          final parts = tail.split('/');
          children[parts.first] = RepositoryEntry(
            parts.first,
            directory: parts.length > 1,
            bytes: parts.length == 1 ? entry.value.length : null,
          );
        }
        return children.values.toList();
      }

      Future<String?> read(String path) async {
        reads++;
        if (revoked) {
          throw StateError('permission revoked');
        }
        return data[path];
      }

      final loader = const RepositoryContextReaderLoader();
      final context = await loader.load(
        rootLabel: '/ssh/project',
        scopedPaths: ['a/result.dart'],
        namedSkills: {'review'},
        readFile: read,
        listDirectory: list,
      );
      expect(context.contextText, contains('root remote'));
      expect(context.contextText, contains('a remote'));
      expect(context.contextText, isNot(contains('b remote')));
      expect(context.contextText, contains('selected body'));
      expect(context.skills.single.name, 'review');
      expect(context.sources.first.path, '/ssh/project/AGENTS.md');
      revoked = true;
      final denied = await loader.load(
        rootLabel: '/ssh/project',
        readFile: read,
        listDirectory: list,
      );
      expect(denied.sources, isEmpty);
      expect(denied.warnings, isNotEmpty);
      expect(reads, greaterThan(4));
      final absent = await loader.load(
        rootLabel: '/ssh/project',
        readFile: read,
        listDirectory: (path) async => [],
      );
      expect(absent.sources, isEmpty);
    },
  );

  test(
    'failed persistence never publishes task/draft or polluted prefs cache',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final original = SharedPreferencesStorePlatform.instance;
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final store = container.read(taskAcceptanceProvider.notifier);
      SharedPreferencesStorePlatform.instance = _FailingPreferences();
      await expectLater(
        store.saveDraft('c', AcceptanceCriteria(description: 'unpersisted')),
        throwsStateError,
      );
      expect(store.draftCriteriaForConversation('c').description, isEmpty);
      await expectLater(
        store.freeze('root', AcceptanceCriteria()),
        throwsStateError,
      );
      expect(container.read(taskAcceptanceProvider), isEmpty);
      expect(prefs.getString(TaskAcceptanceStore.storageKey), isNull);
      SharedPreferencesStorePlatform.instance = original;
      await store.freeze('root', AcceptanceCriteria());
      expect(container.read(taskAcceptanceProvider).containsKey('root'), true);
      await store.freeze('linked', AcceptanceCriteria(), conversationId: 'c');
      await store.saveDraft('c', AcceptanceCriteria(description: 'saved'));
      await store.reviseByUser(
        'linked',
        AcceptanceCriteria(description: 'revised'),
      );
      expect(
        container.read(taskAcceptanceProvider)['linked']?.conversationId,
        'c',
      );
      await store.removeConversation('c');
      expect(
        container.read(taskAcceptanceProvider).containsKey('linked'),
        false,
      );
      expect(container.read(taskAcceptanceProvider).containsKey('root'), true);
      expect(store.draftCriteriaForConversation('c').description, isEmpty);
    },
  );
  test(
    'empty criteria always need explicit acceptance and changed artifact invalidates checks',
    () {
      final empty = TaskAcceptance(
        taskId: 'e',
        criteria: AcceptanceCriteria(manualRequired: false),
      );
      empty.replyComplete = true;
      empty.toolsComplete = true;
      expect(empty.status, TaskAcceptanceStatus.waitingAcceptance);
      final t = TaskAcceptance(
        taskId: 's',
        criteria: AcceptanceCriteria(
          checkIds: ['test'],
          artifactPaths: ['out'],
        ),
      );
      t.recordArtifact(
        path: 'out',
        present: true,
        sha256: 'a' * 64,
        provenance: 'host',
      );
      t.recordCheck(
        id: 'test',
        exitCode: 0,
        invocationId: 'i',
        provenance: 'host',
      );
      t.replyComplete = true;
      t.toolsComplete = true;
      t.acceptByUser('user');
      t.recordArtifact(
        path: 'out',
        present: true,
        sha256: 'b' * 64,
        provenance: 'host',
      );
      expect(t.checks, isEmpty);
      expect(t.manuallyAccepted, false);
      expect(() => t.acceptByUser('user'), throwsStateError);
      final revision = t.mutationRevision;
      t.invalidateAfterMutation();
      expect(t.mutationRevision, revision + 1);
      expect(
        TaskAcceptance.fromJson(t.toJson()).mutationRevision,
        t.mutationRevision,
      );
    },
  );
  test('host observes real exit status and artifact versions', () async {
    final root = await Directory.systemTemp.createTemp('acceptance_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/result.txt');
    await file.writeAsString('v1');
    final t = TaskAcceptance(
      taskId: 'real',
      criteria: AcceptanceCriteria(
        checkIds: ['probe'],
        artifactPaths: ['result.txt'],
      ),
    );
    final result = await Process.run(
      Platform.isWindows ? 'cmd.exe' : '/bin/sh',
      Platform.isWindows ? ['/c', 'exit', '7'] : ['-c', 'exit 7'],
    );
    t.recordCheck(
      id: 'probe',
      exitCode: result.exitCode,
      invocationId: 'process1',
      provenance: 'host:Process.run',
    );
    expect(t.checks['probe']?['exitCode'], 7);
    await observeAcceptanceArtifacts(t, root.path);
    final original = t.artifacts['result.txt']?['sha256'];
    await file.writeAsString('v2');
    await observeAcceptanceArtifacts(t, root.path);
    expect(t.artifacts['result.txt']?['sha256'], isNot(original));
    await file.delete();
    await observeAcceptanceArtifacts(t, root.path);
    expect(t.artifacts['result.txt']?['present'], false);
    expect(t.status, TaskAcceptanceStatus.failed);
  });
  test(
    'frozen criteria require observed checks and artifacts; manual acceptance cannot override failure',
    () {
      final t = TaskAcceptance(
        taskId: 'root',
        criteria: AcceptanceCriteria(
          checkIds: ['dart test'],
          artifactPaths: ['result.txt'],
        ),
      );
      t.replyComplete = true;
      t.toolsComplete = true;
      expect(t.status, TaskAcceptanceStatus.waitingAcceptance);
      expect(() => t.acceptByUser('user'), throwsStateError);
      t.recordCheck(
        id: 'dart test',
        exitCode: 1,
        invocationId: 'call1',
        provenance: 'host:process',
      );
      expect(t.status, TaskAcceptanceStatus.failed);
      t.recordCheck(
        id: 'dart test',
        exitCode: 0,
        invocationId: 'call2',
        provenance: 'host:process',
      );
      t.recordArtifact(
        path: 'result.txt',
        present: true,
        sha256: 'a' * 64,
        provenance: 'host:file',
      );
      expect(t.status, TaskAcceptanceStatus.waitingAcceptance);
      t.acceptByUser('user');
      expect(t.status, TaskAcceptanceStatus.accepted);
      t.recordArtifact(
        path: 'result.txt',
        present: false,
        sha256: '',
        provenance: 'host:file',
      );
      expect(t.status, TaskAcceptanceStatus.failed);
      expect(t.manuallyAccepted, false);
      expect(
        () => t.recordCheck(
          id: 'echo tests passed',
          exitCode: 0,
          invocationId: 'x',
          provenance: 'host',
        ),
        throwsArgumentError,
      );
      final restored = TaskAcceptance.fromJson(t.toJson());
      expect(restored.status, TaskAcceptanceStatus.failed);
    },
  );
  test('writing uses manual review without invented tests', () {
    final t = TaskAcceptance(taskId: 'writing', criteria: AcceptanceCriteria());
    t.replyComplete = true;
    expect(t.status, TaskAcceptanceStatus.replyComplete);
    t.toolsComplete = true;
    expect(t.status, TaskAcceptanceStatus.waitingAcceptance);
    t.acceptByUser('user');
    expect(t.checks, isEmpty);
    expect(t.status, TaskAcceptanceStatus.accepted);
  });
  test(
    'scoped rules load root to cwd; siblings excluded and skills selected',
    () async {
      final root = await Directory.systemTemp.createTemp('repo_context_');
      addTearDown(() => root.delete(recursive: true));
      Future<void> put(String path, String body) async {
        final f = File('${root.path}/$path');
        await f.parent.create(recursive: true);
        await f.writeAsString(body);
      }

      await put('AGENTS.md', 'root rule');
      await put('CLAUDE.md', 'compatible root');
      await put('a/AGENTS.md', 'a rule');
      await put('b/AGENTS.md', 'b rule');
      await put(
        '.agents/skills/review/SKILL.md',
        '---\nname: review\ndescription: Review code\n---\nreview body',
      );
      final context = await const RepositoryContextLoader().load(
        root: root.path,
        cwd: '${root.path}/a',
        namedSkills: {'review'},
      );
      expect(context.sources.map((s) => s.content), [
        'root rule',
        'compatible root',
        'a rule',
        '---\nname: review\ndescription: Review code\n---\nreview body',
      ]);
      expect(context.skills.single.name, 'review');
      expect(context.sources.first.hash.length, 64);
      final sibling = await const RepositoryContextLoader().load(
        root: root.path,
        cwd: '${root.path}/b',
      );
      expect(sibling.contextText, contains('b rule'));
      expect(sibling.contextText, isNot(contains('a rule')));
      expect(sibling.contextText, isNot(contains('review body')));
      final owned = await const RepositoryContextLoader().load(
        root: root.path,
        cwd: root.path,
        scopedPaths: ['a/file.dart'],
      );
      expect(owned.contextText, contains('a rule'));
      expect(owned.contextText, isNot(contains('b rule')));
      final denied = await const RepositoryContextLoader().load(
        root: root.path,
        cwd: root.path,
        scopedPaths: ['a/file.dart'],
        canRead: (path) => !path.replaceAll('\\', '/').contains('/a/'),
      );
      expect(denied.contextText, isNot(contains('a rule')));

      await expectLater(
        const RepositoryContextLoader().load(
          root: root.path,
          cwd: root.parent.path,
        ),
        throwsArgumentError,
      );
      final limited = await const RepositoryContextLoader(
        maxFileBytes: 2,
      ).load(root: root.path, cwd: '${root.path}/a');
      expect(limited.sources, isEmpty);
      expect(limited.warnings, isNotEmpty);
    },
  );
}
