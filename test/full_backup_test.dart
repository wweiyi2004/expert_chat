import 'dart:convert';
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
        (p) => p['schemaVersion'] = 17,
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
    expect(find.text('数据版本 15 → 16'), findsOneWidget);
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
