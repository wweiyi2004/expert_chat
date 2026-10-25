import 'package:expert_chat/domain/task_core/task_core.dart';
import 'package:expert_chat/domain/task_core/task_acceptance.dart';
import 'dart:convert';
import 'package:expert_chat/data/ui_prefs.dart';
import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:expert_chat/data/backup_codec.dart';
import 'package:expert_chat/data/backup_migrations.dart';
import 'package:expert_chat/features/settings/widgets/backup_compatibility_notice.dart';
import 'package:flutter/material.dart';
import 'package:expert_chat/data/backup_journal.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/full_backup_service.dart';
import 'package:expert_chat/data/library_file_store.dart';
import 'package:expert_chat/data/library_repository.dart';
import 'package:expert_chat/data/memory_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/memory/memory_codec.dart';
import 'package:expert_chat/domain/memory/memory_entry.dart';

class _Memory implements MemoryStore {
  String value = '';
  bool failOnce = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String markdown) async {
    value = markdown;
    if (failOnce) {
      failOnce = false;
      throw StateError('disk failure');
    }
  }

  @override
  Future<String> locationLabel() async => 'test';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory temp;
  late LibraryFileStore files;
  late _Memory memory;
  late BackupJournal journal;
  late SharedPreferences prefs;
  late FullBackupService service;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    temp = await Directory.systemTemp.createTemp('expert-chat-backup-test-');
    files = LibraryFileStore(rootOverride: '${temp.path}/library');
    memory = _Memory();
    journal = BackupJournal(pathOverride: '${temp.path}/journal.json');
    SharedPreferences.setMockInitialValues({
      'themeMode': 1,
      'providerProfiles': 'SECRET',
      'terminalPassword': 'SECRET',
    });
    prefs = await SharedPreferences.getInstance();
    service = FullBackupService(db, files, memory, prefs, journal);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  test('default backup restore keeps the current UI preferences', () async {
    const imported = UiPrefs(
      colorTheme: ColorThemePref.wadaViolet,
      workbenchWidth: 724,
      sidebarCollapsedGroups: ['work:imported'],
    );
    const existing = UiPrefs(
      colorTheme: ColorThemePref.forest,
      workbenchWidth: 616,
      sidebarCollapsedGroups: ['chat:existing'],
    );
    await prefs.setString('uiPrefs', jsonEncode(imported.toJson()));
    final bytes = await service.exportBackup();
    await prefs.setString('uiPrefs', jsonEncode(existing.toJson()));
    await service.restoreCopies(await service.preview(bytes));
    final restored = UiPrefs.fromJson(
      jsonDecode(prefs.getString('uiPrefs')!) as Map<String, dynamic>,
    );
    expect(restored.toJson(), existing.toJson());
  });

  test('redesign UI preferences survive full backup restore', () async {
    const original = UiPrefs(
      colorTheme: ColorThemePref.wadaViolet,
      workbenchWidth: 724,
      sidebarCollapsedGroups: ['work:local', 'chat:docs'],
    );
    await prefs.setString('uiPrefs', jsonEncode(original.toJson()));
    final bytes = await service.exportBackup();
    await prefs.remove('uiPrefs');
    await service.restoreCopies(
      await service.preview(bytes),
      restorePreferences: true,
    );
    final restored = UiPrefs.fromJson(
      jsonDecode(prefs.getString('uiPrefs')!) as Map<String, dynamic>,
    );
    expect(restored.colorTheme, original.colorTheme);
    expect(restored.workbenchWidth, original.workbenchWidth);
    expect(restored.sidebarCollapsedGroups, original.sidebarCollapsedGroups);
  });

  Future<Uint8List> seed() async {
    final now = DateTime.now();
    await db
        .into(db.projects)
        .insert(
          ProjectsCompanion.insert(
            id: 'p',
            name: '项目',
            instructions: const Value('说明'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await DriftConversationRepository(db).saveConversation(
      Conversation(
        id: 'c',
        projectId: 'p',
        messages: [
          ChatMessage(id: 'u', role: MessageRole.user, content: '问题'),
          ChatMessage(
            id: 'a',
            parentId: 'u',
            role: MessageRole.assistant,
            content: '答案',
          ),
        ],
        activeChildren: {'': 'u', 'u': 'a'},
      ),
    );
    final item = await LibraryRepository(db, files).importBytes(
      name: '你好.txt',
      mimeType: 'text/plain',
      bytes: Uint8List.fromList(utf8.encode('素材内容')),
    );
    await db
        .into(db.projectFiles)
        .insert(
          ProjectFilesCompanion.insert(projectId: 'p', libraryItemId: item.id),
        );
    memory.value = const MemoryMarkdownCodec().encode(
      MemoryDocument(
        entries: [
          MemoryEntry(
            id: 'm',
            content: 'remember',
            sourceConversationId: 'c',
            sourceMessageId: 'u',
          ),
        ],
      ),
    );
    return service.exportBackup();
  }

  Future<void> seedTaskRecords() async {
    await seed();
    final core = TaskCore(
      rootId: 'independent-root',
      goal: 'preserve task goal',
    );
    core.agentTaskId = 'a';
    core.agentRootId = 'machine-child';
    core.lineage.add('a');
    core.target = {
      'workspaceId': 'machine-workspace',
      'root': 'C:/original',
      'sshProfileId': '',
      'remoteRoot': '',
      'approval': 'ask',
      'network': false,
    };
    core.receive('event-one', 'durable external result', 'a');
    await prefs.setString(
      'chatSessionJournal.v1',
      jsonEncode([
        {
          'conversationId': 'c',
          'taskId': 'a',
          'status': 'running',
          'updatedAt': DateTime.now().toIso8601String(),
          'phase': 'working',
          'queuedEvents': 1,
          'taskState': core.toJson(),
        },
        {
          'conversationId': 'orphan',
          'taskId': null,
          'status': 'completed',
          'updatedAt': DateTime.now().toIso8601String(),
          'taskState': {},
        },
      ]),
    );
    final task = TaskAcceptance(
      taskId: core.rootId,
      conversationId: 'c',
      criteria: AcceptanceCriteria(
        checkIds: ['dart test'],
        artifactPaths: ['result.txt'],
      ),
    );
    task.recordCheck(
      id: 'dart test',
      exitCode: 0,
      invocationId: 'command-one',
      provenance: 'host:process',
    );
    task.recordArtifact(
      path: 'result.txt',
      present: true,
      sha256: 'a' * 64,
      provenance: 'host:file',
    );
    task.replyComplete = true;
    task.toolsComplete = true;
    task.acceptByUser('user');
    await prefs.setString(
      'taskAcceptance.v1',
      jsonEncode({
        'tasks': [
          task.toJson(),
          {
            ...task.toJson(),
            'taskId': 'orphan-task',
            'conversationId': 'orphan',
          },
        ],
        'drafts': {
          'c': task.criteria.toJson(),
          'orphan': task.criteria.toJson(),
        },
      }),
    );
  }

  test(
    'full backup remaps durable task identity additively without importing authority',
    () async {
      await seedTaskRecords();
      final originalSession = prefs.getString('chatSessionJournal.v1');
      final originalAcceptance =
          jsonDecode(prefs.getString('taskAcceptance.v1')!) as Map;
      final bytes = await service.exportBackup();
      final decoded = BackupCodec.decode(bytes);
      final exported = decoded['preferences'] as Map;
      expect(exported.containsKey('terminalPassword'), false);
      expect(exported.containsKey('providerProfiles'), false);
      expect(
        (jsonDecode(exported['chatSessionJournal.v1'] as String) as List)
            .length,
        1,
      );
      final exportedAcceptance =
          jsonDecode(exported['taskAcceptance.v1'] as String) as Map;
      expect((exportedAcceptance['tasks'] as List).length, 1);
      expect((exportedAcceptance['drafts'] as Map).keys, ['c']);
      await service.restoreCopies(await service.preview(bytes));
      final sessions =
          jsonDecode(prefs.getString('chatSessionJournal.v1')!) as List;
      expect(sessions.take(2), jsonDecode(originalSession!) as List);
      final imported = sessions.last as Map;
      expect(imported['conversationId'], isNot('c'));
      expect(imported['status'], 'interrupted');
      final core = imported['taskState'] as Map;
      expect(core['rootId'], isNot('independent-root'));
      expect(core['target'], isEmpty);
      expect(core['agentRootId'], isNull);
      expect(core['resumeRequired'], true);
      final message = await db
          .customSelect(
            'SELECT convo_id FROM messages WHERE id = ?',
            variables: [Variable<String>(imported['taskId'] as String)],
          )
          .getSingle();
      expect(message.data['convo_id'], imported['conversationId']);
      expect(core['agentTaskId'], imported['taskId']);
      expect(core['lineage'], [imported['taskId']]);
      final event = (core['inbox'] as List).single as Map;
      expect(event['taskId'], imported['taskId']);
      expect(event['id'], isNot('event-one'));
      final a = jsonDecode(prefs.getString('taskAcceptance.v1')!) as Map;
      expect((a['tasks'] as List).take(2), originalAcceptance['tasks']);
      final restored = TaskAcceptance.fromJson(
        Map<String, dynamic>.from((a['tasks'] as List).last as Map),
      );
      expect(restored.taskId, core['rootId']);
      expect(restored.conversationId, imported['conversationId']);
      expect(restored.requiresReverification, true);
      expect(restored.manuallyAccepted, false);
      expect(restored.machineVerified, false);
      expect(restored.checks['dart test']?['exitCode'], 0);
      expect(restored.acceptedBy, 'user');
      expect(
        (a['drafts'] as Map).containsKey(imported['conversationId']),
        true,
      );
    },
  );
  test(
    'task backup rejects unknown fields and orphan imported associations',
    () async {
      await seedTaskRecords();
      final payload = BackupCodec.decode(await service.exportBackup());
      final preferences = payload['preferences'] as Map;
      final sessions =
          jsonDecode(preferences['chatSessionJournal.v1'] as String) as List;
      (sessions.single['taskState'] as Map)['apiToken'] = 'must reject';
      preferences['chatSessionJournal.v1'] = jsonEncode(sessions);
      await expectLater(
        service.preview(BackupCodec.encode(payload)),
        throwsFormatException,
      );
      (sessions.single['taskState'] as Map).remove('apiToken');
      sessions.single['conversationId'] = 'missing-conversation';
      preferences['chatSessionJournal.v1'] = jsonEncode(sessions);
      await expectLater(
        service.preview(BackupCodec.encode(payload)),
        throwsFormatException,
      );
    },
  );
  test(
    'task restore failure rolls back journal and local records; old backups add no invented state',
    () async {
      final oldBytes = await seed();
      await prefs.remove('chatSessionJournal.v1');
      await prefs.remove('taskAcceptance.v1');
      await service.restoreCopies(await service.preview(oldBytes));
      expect(prefs.containsKey('chatSessionJournal.v1'), false);
      expect(prefs.containsKey('taskAcceptance.v1'), false);
      // Populate task data on the original saved conversation without reseeding rows.
      final core = TaskCore(rootId: 'rollback-root');
      await prefs.setString(
        'chatSessionJournal.v1',
        jsonEncode([
          {
            'conversationId': 'c',
            'status': 'completed',
            'updatedAt': DateTime.now().toIso8601String(),
            'taskState': core.toJson(),
          },
        ]),
      );
      await prefs.setString(
        'taskAcceptance.v1',
        jsonEncode({
          'tasks': [
            TaskAcceptance(
              taskId: core.rootId,
              conversationId: 'c',
              criteria: AcceptanceCriteria(),
            ).toJson(),
          ],
          'drafts': {},
        }),
      );
      final bytes = await service.exportBackup();
      final oldJournal = prefs.getString('chatSessionJournal.v1'),
          oldAcceptance = prefs.getString('taskAcceptance.v1');
      final count =
          (await db
                  .customSelect('SELECT COUNT(*) AS n FROM conversations')
                  .getSingle())
              .read<int>('n');
      memory.failOnce = true;
      await expectLater(
        service.restoreCopies(await service.preview(bytes)),
        throwsStateError,
      );
      expect(prefs.getString('chatSessionJournal.v1'), oldJournal);
      expect(prefs.getString('taskAcceptance.v1'), oldAcceptance);
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM conversations')
                .getSingle())
            .read<int>('n'),
        count,
      );
      expect(await journal.read(), isNull);
    },
  );

  test(
    'work memory and user pins follow imported conversation copies without replay state',
    () async {
      await seed();
      await prefs.setString(
        'workMemory.v1',
        jsonEncode({
          'c': {
            'revision': 4,
            'user_pins': 'keep user constraint',
            'plan': 'verify final artifacts',
            'summary': 'public task notes',
            'compact_revision': 4,
          },
        }),
      );
      await prefs.setString(
        'workOperations.v1',
        'SENSITIVE_DEVICE_LOCAL_EXECUTION',
      );
      final bytes = await service.exportBackup();
      final payload = BackupCodec.decode(bytes);
      expect(
        jsonEncode(payload),
        isNot(contains('SENSITIVE_DEVICE_LOCAL_EXECUTION')),
      );
      expect(
        jsonDecode(
          payload['preferences']['workMemory.v1'],
        )['c'].containsKey('compact_revision'),
        isFalse,
      );
      await service.restoreCopies(await service.preview(bytes));
      final conversations = await DriftConversationRepository(db).loadAll();
      final copy = conversations.singleWhere((c) => c.id != 'c');
      final memory = jsonDecode(prefs.getString('workMemory.v1')!) as Map;
      expect(memory['c']['user_pins'], 'keep user constraint');
      expect(memory[copy.id]['user_pins'], 'keep user constraint');
      expect(memory[copy.id]['plan'], 'verify final artifacts');
      expect(
        prefs.getString('workOperations.v1'),
        'SENSITIVE_DEVICE_LOCAL_EXECUTION',
      );
    },
  );

  Future<Uint8List> legacyBackup() async {
    final payload = BackupCodec.decode(await seed());
    payload['schemaVersion'] = 15;
    final tables = payload['tables'] as Map<String, dynamic>;
    for (final table in ['projects', 'project_files', 'generation_records']) {
      tables.remove(table);
    }
    for (final row in tables['conversations'] as List) {
      (row as Map).remove('project_id');
    }
    return BackupCodec.encode(payload);
  }

  test(
    'export and preview agree at the record limit and reject above it',
    () async {
      await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'large-history',
              updatedAt: DateTime(2026),
            ),
          );
      await db.customStatement(
        '''
      WITH RECURSIVE seq(n) AS (
        SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < ?
      )
      INSERT INTO messages(id,convo_id,parent_id,role,content,created_at,seq)
      SELECT 'message-' || n, 'large-history',
             CASE WHEN n=1 THEN NULL ELSE 'message-' || (n-1) END,
             'user', 'message content', 0, n FROM seq
    ''',
        [FullBackupService.maxRecords - 1],
      );

      final bytes = await service.exportBackup();
      final preview = await service.preview(bytes);
      expect(preview.count('messages'), FullBackupService.maxRecords - 1);
      expect(preview.count('conversations'), 1);

      await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'one-too-many',
              updatedAt: DateTime(2026),
            ),
          );
      await expectLater(service.exportBackup(), throwsFormatException);
      final payload = BackupCodec.decode(bytes);
      (payload['tables']['conversations'] as List).add({
        ...(payload['tables']['conversations'] as List).single as Map,
        'id': 'one-too-many',
      });
      await expectLater(
        service.preview(BackupCodec.encode(payload)),
        throwsFormatException,
      );
    },
  );

  test(
    'known v15 archive upgrades into copies and preserves original records',
    () async {
      final bytes = await legacyBackup();
      final preview = await service.preview(bytes);
      expect(preview.sourceSchemaVersion, 15);
      expect(preview.targetSchemaVersion, db.schemaVersion);
      expect(db.schemaVersion, BackupMigrations.currentSchema);
      expect(preview.requiresUpgrade, isTrue);
      expect(BackupCodec.decode(bytes)['schemaVersion'], 15);
      await service.restoreCopies(preview);
      final conversations = await DriftConversationRepository(db).loadAll();
      expect(conversations, hasLength(2));
      final original = conversations.singleWhere((c) => c.id == 'c');
      final copy = conversations.singleWhere((c) => c.id != 'c');
      expect(original.projectId, 'p');
      expect(copy.projectId, isNull);
      expect(copy.activePath.map((m) => m.content), ['问题', '答案']);
      expect(copy.messages.first.id, isNot('u'));
      final library = await LibraryRepository(db, files).list();
      expect(library, hasLength(2));
      for (final item in library) {
        expect(
          utf8.decode((await files.readBytes(item.relativePath))!),
          '素材内容',
        );
      }
      expect(await db.select(db.projects).get(), hasLength(1));
    },
  );

  test(
    'archive migration refuses future versions and unknown legacy fields before writing',
    () async {
      final bytes = await legacyBackup();
      for (final change in <void Function(Map<String, dynamic>)>[
        (p) => p['schemaVersion'] = 18,
        (p) => p['schemaVersion'] = 14,
        (p) => p['schemaVersion'] = '15',
        (p) => p['tables']['projects'] = [],
        (p) => p['tables']['conversations'][0]['project_id'] = 'lost-project',
        (p) => p['tables']['messages'][0]['future_field'] = 'must not discard',
        (p) => p['createdAt'] = 42,
        (p) => p['futureMetadata'] = {'data': 'must not discard'},
      ]) {
        final payload = BackupCodec.decode(bytes);
        change(payload);
        await expectLater(
          service.preview(BackupCodec.encode(payload)),
          throwsFormatException,
        );
        expect(await db.select(db.conversations).get(), hasLength(1));
        expect(await journal.read(), isNull);
      }
    },
  );

  test(
    'v16 archive preserves generations without guessing their protocol',
    () async {
      await seed();
      await db
          .into(db.generationRecords)
          .insert(
            GenerationRecordsCompanion.insert(
              id: 'legacy-generation',
              conversationId: const Value('c'),
              messageId: const Value('a'),
              originalPrompt: '原始描述',
              optimizedPrompt: '发送描述',
              revisedPrompt: const Value('返回描述'),
              model: 'gemini-2.5-flash-image',
              providerHost: 'https://media.example',
              apiFormat: const Value('geminiNative'),
              imageSize: '1024x1024',
              createdAt: DateTime(2026),
            ),
          );
      final payload = BackupCodec.decode(await service.exportBackup());
      payload['schemaVersion'] = 16;
      final row =
          (payload['tables']['generation_records'] as List).single as Map;
      row.remove('api_format');
      final bytes = BackupCodec.encode(payload);
      final preview = await service.preview(bytes);
      expect(preview.sourceSchemaVersion, 16);
      expect(preview.targetSchemaVersion, 17);
      expect(preview.requiresUpgrade, isTrue);
      await service.restoreCopies(preview);
      final copied = (await db.select(db.generationRecords).get()).singleWhere(
        (record) => record.id != 'legacy-generation',
      );
      expect(copied.apiFormat, isNull);
      expect(copied.model, 'gemini-2.5-flash-image');
      expect(copied.optimizedPrompt, '发送描述');
      expect(copied.revisedPrompt, '返回描述');
      expect(copied.providerHost, 'https://media.example');
      expect(copied.imageSize, '1024x1024');
      expect(copied.conversationId, isNot('c'));
      expect(
        BackupCodec.decode(
          bytes,
        )['tables']['generation_records'][0].containsKey('api_format'),
        isFalse,
      );

      for (final mutate in <void Function(Map)>[
        (r) => r['api_format'] = 'geminiNative',
        (r) => r['future_field'] = 'must retain',
        (r) => r.remove('model'),
      ]) {
        final invalid = BackupCodec.decode(bytes);
        mutate(invalid['tables']['generation_records'][0] as Map);
        await expectLater(
          service.preview(BackupCodec.encode(invalid)),
          throwsFormatException,
        );
      }
      expect(await db.select(db.generationRecords).get(), hasLength(2));
    },
  );

  testWidgets('upgraded backup preview explains unclassified conversations', (
    tester,
  ) async {
    final preview = await tester.runAsync(
      () async => service.preview(await legacyBackup()),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BackupCompatibilityNotice(preview: preview!)),
      ),
    );
    expect(find.text('旧版备份已准备好转换'), findsOneWidget);
    expect(find.textContaining('未归类'), findsOneWidget);
    expect(find.text('数据版本 15 → 17'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'roundtrip keeps existing data and remaps tree, project, memory and files',
    () async {
      final backup = await seed();
      final preview = await service.preview(backup);
      expect(preview.count('conversations'), 1);
      expect(preview.memories, 1);
      await prefs.setInt('themeMode', 2);
      await service.restoreCopies(preview);
      final conversations = await DriftConversationRepository(db).loadAll();
      expect(conversations, hasLength(2));
      final copy = conversations.firstWhere((c) => c.id != 'c');
      expect(copy.projectId, isNot('p'));
      expect(copy.activePath.map((m) => m.content), ['问题', '答案']);
      expect(copy.messages.first.id, isNot('u'));
      final importedMemory = const MemoryMarkdownCodec()
          .decode(memory.value)
          .entries
          .last;
      expect(importedMemory.sourceConversationId, copy.id);
      final library = await LibraryRepository(db, files).list();
      expect(library, hasLength(2));
      for (final item in library) {
        expect(
          utf8.decode((await files.readBytes(item.relativePath))!),
          '素材内容',
        );
      }
      expect(prefs.getInt('themeMode'), 2);
      expect(prefs.getString('providerProfiles'), 'SECRET');
      expect(await journal.read(), isNull);
      expect(await db.select(db.backupImports).get(), isEmpty);
    },
  );

  test(
    'credentials excluded and preferences only restored on opt-in',
    () async {
      final bytes = await seed();
      final payload = BackupCodec.decode(bytes);
      expect(jsonEncode(payload), isNot(contains('SECRET')));
      await prefs.setInt('themeMode', 2);
      await service.restoreCopies(
        await service.preview(bytes),
        restorePreferences: true,
      );
      expect(prefs.getInt('themeMode'), 1);
    },
  );

  test(
    'corruption, unsupported versions, injected tables and missing files rejected',
    () async {
      final bytes = await seed();
      final damaged = Uint8List.fromList(bytes)..[44] ^= 1;
      await expectLater(service.preview(damaged), throwsFormatException);
      await expectLater(
        service.preview(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
        throwsFormatException,
      );
      for (final change in <void Function(Map<String, dynamic>)>[
        (p) => p['version'] = 99,
        (p) => p['schemaVersion'] = 999,
        (p) => p['tables']['injected; DELETE FROM conversations'] = [],
        (p) => p['files'].clear(),
        (p) => p['preferences']['api_key'] = 'bad',
      ]) {
        final p = BackupCodec.decode(bytes);
        change(p);
        await expectLater(
          service.preview(BackupCodec.encode(p)),
          throwsFormatException,
        );
      }
      expect(await db.select(db.conversations).get(), hasLength(1));
    },
  );

  test(
    'failed auxiliary write rolls SQL and newly staged files back',
    () async {
      final preview = await service.preview(await seed());
      final before = memory.value;
      final originalPaths =
          (await Directory(
                '${temp.path}/library',
              ).list(recursive: true).toList())
              .whereType<File>()
              .map((f) => f.path)
              .toSet();
      memory.failOnce = true;
      await expectLater(service.restoreCopies(preview), throwsStateError);
      expect(await db.select(db.conversations).get(), hasLength(1));
      expect(memory.value, before);
      expect(await journal.read(), isNull);
      final after =
          (await Directory(
                '${temp.path}/library',
              ).list(recursive: true).toList())
              .whereType<File>()
              .map((f) => f.path)
              .toSet();
      expect(after, originalPaths);
    },
  );

  test(
    'startup recovers uncommitted journal, keeps committed auxiliary writes',
    () async {
      await seed();
      final before = memory.value;
      final path = await files.writeBytes(
        id: 'staged',
        fileName: 'x.txt',
        image: false,
        bytes: Uint8List(2),
      );
      await journal.write({
        'id': 'restore',
        'memory': before,
        'files': [path],
        'preferences': {'themeMode': 1},
      });
      memory.value = 'partial';
      await prefs.setInt('themeMode', 2);
      await service.recoverPending();
      expect(memory.value, before);
      expect(prefs.getInt('themeMode'), 1);
      expect(await files.readBytes(path), isNull);
      await journal.write({
        'id': 'committed',
        'memory': before,
        'files': [],
        'preferences': {},
      });
      await db
          .into(db.backupImports)
          .insert(
            BackupImportsCompanion.insert(
              id: 'committed',
              committedAt: DateTime.now(),
            ),
          );
      memory.value = 'committed memory';
      await service.recoverPending();
      expect(memory.value, 'committed memory');
    },
  );

  test(
    'restores learning references, character/world bindings and generation lineage',
    () async {
      await seed();
      final now = DateTime.now();
      await db
          .into(db.characterCards)
          .insert(
            CharacterCardsCompanion.insert(
              id: 'char',
              name: '角色',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.worldInfoEntries)
          .insert(
            WorldInfoEntriesCompanion.insert(
              id: 'world',
              title: '世界',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final repo = DriftConversationRepository(db);
      final c = await repo.loadConversation('c');
      await repo.saveConversation(
        c.copyWith(characterId: 'char', worldInfoIds: ['world']),
      );
      for (final kind in ['course', 'node']) {
        await db
            .into(db.studyEntities)
            .insert(
              StudyEntitiesCompanion.insert(
                kind: kind,
                id: kind,
                payloadJson: jsonEncode({
                  'id': kind,
                  'courseId': 'course',
                  'text': 'course',
                }),
                updatedAt: now,
              ),
            );
      }
      await db
          .into(db.studySessions)
          .insert(
            StudySessionsCompanion.insert(
              conversationId: 'c',
              path: 'tutor',
              tutorStyle: 'mixed',
              courseId: const Value('course'),
              nodeId: const Value('node'),
              createdAt: now,
            ),
          );
      final item = (await db.select(db.libraryItems).get()).single;
      for (final id in ['gen1', 'gen2']) {
        await db
            .into(db.generationRecords)
            .insert(
              GenerationRecordsCompanion.insert(
                id: id,
                libraryItemId: Value(item.id),
                conversationId: const Value('c'),
                messageId: const Value('a'),
                parentGenerationId: Value(id == 'gen2' ? 'gen1' : null),
                originalPrompt: 'course',
                optimizedPrompt: 'u',
                model: 'model',
                providerHost: 'https://media.example',
                apiFormat: const Value('geminiNative'),
                imageSize: '1024x1024',
                referencesJson: Value(
                  jsonEncode([
                    {'libraryItemId': item.id, 'sha256': item.sha256},
                  ]),
                ),
                createdAt: now,
              ),
            );
      }
      memory.value += '\n手工备注：请保留此行\n';
      await service.restoreCopies(
        await service.preview(await service.exportBackup()),
      );
      expect('手工备注：请保留此行'.allMatches(memory.value), hasLength(2));
      final imported = (await repo.loadAll()).firstWhere((c) => c.id != 'c');
      expect(imported.characterId, isNot('char'));
      expect(imported.worldInfoIds.single, isNot('world'));
      final session = (await db.select(db.studySessions).get()).firstWhere(
        (s) => s.conversationId == imported.id,
      );
      final node = (await db.select(db.studyEntities).get()).firstWhere(
        (e) => e.id == session.nodeId,
      );
      expect(jsonDecode(node.payloadJson)['courseId'], session.courseId);
      expect(jsonDecode(node.payloadJson)['text'], 'course');
      final gens = (await db.select(db.generationRecords).get())
          .where((g) => g.conversationId == imported.id)
          .toList();
      expect(gens, hasLength(2));
      expect(
        gens
            .singleWhere((g) => g.parentGenerationId != null)
            .parentGenerationId,
        gens.singleWhere((g) => g.parentGenerationId == null).id,
      );
      expect(gens.first.originalPrompt, 'course');
      expect(gens.first.optimizedPrompt, 'u');
      expect(
        gens.every((record) => record.apiFormat == 'geminiNative'),
        isTrue,
      );
      expect(
        jsonDecode(gens.first.referencesJson)[0]['libraryItemId'],
        gens.first.libraryItemId,
      );
    },
  );

  test(
    'invalid message tree and JSON field shape rejected before writes',
    () async {
      final bytes = await seed();
      for (final change in <void Function(Map<String, dynamic>)>[
        (p) => p['tables']['messages'][0]['parent_id'] = 'a',
        (p) => p['tables']['messages'][0]['attachments_json'] = '{}',
        (p) => p['tables']['messages'][0]['content'] = 17,
      ]) {
        final payload = BackupCodec.decode(bytes);
        change(payload);
        await expectLater(
          service.preview(BackupCodec.encode(payload)),
          throwsFormatException,
        );
      }
      expect(await journal.read(), isNull);
    },
  );

  test(
    'archive paths never used as disk targets and library traversal rejected',
    () async {
      final payload = BackupCodec.decode(await seed());
      payload['tables']['library_items'][0]['relative_path'] =
          '../../outside.txt';
      await service.restoreCopies(
        await service.preview(BackupCodec.encode(payload)),
      );
      final rows = await db.select(db.libraryItems).get();
      expect(rows.every((r) => !r.relativePath.contains('..')), isTrue);
      await expectLater(files.readBytes('../outside'), throwsFormatException);
      await expectLater(
        files.delete('files/../../outside'),
        throwsFormatException,
      );
      await expectLater(
        files.writeBytes(
          id: '../outside',
          fileName: 'x',
          image: false,
          bytes: Uint8List(0),
        ),
        throwsFormatException,
      );
    },
  );
}
