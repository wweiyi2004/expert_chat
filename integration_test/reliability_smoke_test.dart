import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/backup_journal.dart';
import 'package:expert_chat/data/backup_codec.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/full_backup_service.dart';
import 'package:expert_chat/data/library_file_store.dart';
import 'package:expert_chat/data/library_repository.dart';
import 'package:expert_chat/data/memory_file_store.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:expert_chat/platform/preferences.dart';

// All application storage is redirected before constructing any repositories.
// Model traffic and settings use fixtures; this test never uses personal keys.
class _SandboxPaths extends PathProviderPlatform {
  _SandboxPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/documents';
  @override
  Future<String?> getTemporaryPath() async => '$root/cache';
  @override
  Future<String?> getExternalStoragePath() async => '$root/external';
}

class _Settings extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      id: 'smoke',
      name: 'Offline fixture',
      baseUrl: 'https://example.invalid',
      chatModel: 'smoke-model',
      reasonerModel: 'smoke-model',
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'test-only',
      searchMode: SearchMode.off,
      imageGenMode: ImageGenMode.off,
      studyModeEnabled: false,
      creationModeEnabled: false,
    );
  }
}

class _InterruptedLlm implements LlmProvider {
  int calls = 0;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    calls++;
    yield ChatChunk(contentDelta: 'CHECKPOINT ${'saved ' * 1500}');
    await cancelToken!.whenCancel;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native upgrade, interrupted turn, backup and recovery', (
    tester,
  ) async {
    final sandbox = await Directory.systemTemp.createTemp(
      'expert-chat-native-smoke-',
    );
    final originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _SandboxPaths(sandbox.path);
    SharedPreferences.setMockInitialValues({'themeMode': 0});
    final prefs = await SharedPreferences.getInstance();
    final databaseFile = File('${sandbox.path}/archive.sqlite');
    final files = LibraryFileStore();
    final memory = MemoryFileStore(prefs);
    final journal = BackupJournal();
    final llm = _InterruptedLlm();
    AppDatabase? database;
    ProviderContainer? container;

    ProviderContainer openController(AppDatabase db) => ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(prefs),
        settingsControllerProvider.overrideWith(_Settings.new),
        llmProvider.overrideWithValue(llm),
        libraryFileStoreProvider.overrideWithValue(files),
        memoryStoreProvider.overrideWithValue(memory),
      ],
    );

    try {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Verifying local data'))),
      );
      await tester.runAsync(() async {
        // Build a v15 fixture on disk, then reopen through the real migration.
        var db = database = AppDatabase(NativeDatabase(databaseFile));
        await DriftConversationRepository(db).saveConversation(
          Conversation(
            id: 'legacy',
            title: 'Preserved archive',
            messages: [
              ChatMessage(
                id: 'old-user',
                role: MessageRole.user,
                content: 'History survives upgrade',
              ),
            ],
            activeChildren: {kRootKey: 'old-user'},
          ),
        );
        await db.customStatement(
          'DROP INDEX idx_conversations_project_updated',
        );
        await db.customStatement(
          'ALTER TABLE conversations DROP COLUMN project_id',
        );
        for (final table in [
          'project_files',
          'generation_records',
          'backup_imports',
          'projects',
        ]) {
          await db.customStatement('DROP TABLE $table');
        }
        await db.customStatement('PRAGMA user_version = 15');
        // Build the archive from the physical v15 table shape, before reopening
        // the database through the application's current schema migration.
        final legacyTables = <String, dynamic>{};
        for (final name in [
          'character_cards',
          'world_info_entries',
          'library_items',
          'conversations',
          'messages',
          'study_entities',
          'study_sessions',
        ]) {
          legacyTables[name] = [
            for (final row
                in await db.customSelect('SELECT * FROM "$name"').get())
              row.data,
          ];
        }
        final legacyArchive = BackupCodec.encode({
          'version': BackupCodec.version,
          'schemaVersion': 15,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'tables': legacyTables,
          'files': <String, dynamic>{},
          'memory': '',
          'preferences': <String, dynamic>{},
        });
        await db.close();
        db = database = AppDatabase(NativeDatabase(databaseFile));
        final upgraded = await DriftConversationRepository(
          db,
        ).loadConversation('legacy');
        expect(upgraded.messages.single.content, 'History survives upgrade');
        expect(await db.select(db.projects).get(), isEmpty);
        final migrationService = FullBackupService(
          db,
          files,
          memory,
          prefs,
          journal,
        );
        final legacyPreview = await migrationService.preview(legacyArchive);
        expect(legacyPreview.requiresUpgrade, isTrue);
        await migrationService.restoreCopies(legacyPreview);
        final restoredCopies = await DriftConversationRepository(db).loadAll();
        expect(restoredCopies, hasLength(2));
        final imported = restoredCopies.singleWhere((c) => c.id != 'legacy');
        expect(imported.messages.single.content, 'History survives upgrade');
        expect(imported.projectId, isNull);
        // Remove only this test copy so the remaining existing scenarios keep
        // their independent, fixed row-count assertions.
        await DriftConversationRepository(db).deleteConversation(imported.id);

        final active = container = openController(db);
        await active.read(chatControllerProvider.future);
        final send = active
            .read(chatControllerProvider.notifier)
            .sendMessage('Checkpoint this turn');
        final repo = DriftConversationRepository(db);
        var checkpointed = false;
        for (var attempt = 0; attempt < 100; attempt++) {
          final stored = await repo.loadConversation('legacy');
          checkpointed = stored.messages.any(
            (m) => m.content.startsWith('CHECKPOINT'),
          );
          if (checkpointed) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          checkpointed,
          isTrue,
          reason: 'An in-flight reply must reach disk before teardown',
        );
        // Model interruption is simulated; a true OS force-stop is a separate
        // device validation step documented in docs/RELIABILITY.md.
        active.dispose();
        container = null;
        await send;
        await db.close();
        db = database = AppDatabase(NativeDatabase(databaseFile));
        final reopened = await DriftConversationRepository(
          db,
        ).loadConversation('legacy');
        expect(reopened.messages.first.content, 'History survives upgrade');
        expect(reopened.messages.last.content, startsWith('CHECKPOINT'));
        expect(llm.calls, 1);

        final assetBytes = Uint8List.fromList(
          utf8.encode('Persistent library bytes'),
        );
        await LibraryRepository(db, files).importBytes(
          name: 'evidence.txt',
          mimeType: 'text/plain',
          bytes: assetBytes,
        );
        await memory.write('# Local memory\n');
        var service = FullBackupService(db, files, memory, prefs, journal);
        final archive = File('${sandbox.path}/roundtrip.ecbackup');
        await archive.writeAsBytes(await service.exportBackup(), flush: true);
        await db.close();
        db = database = AppDatabase(NativeDatabase(databaseFile));
        service = FullBackupService(db, files, memory, prefs, journal);
        await service.restoreCopies(
          await service.preview(await archive.readAsBytes()),
        );
        expect(await db.select(db.conversations).get(), hasLength(2));
        expect(
          (await DriftConversationRepository(
            db,
          ).loadConversation('legacy')).messages,
          hasLength(3),
        );
        final items = await db.select(db.libraryItems).get();
        expect(items, hasLength(2));
        for (final item in items) {
          expect(await files.readBytes(item.relativePath), assetBytes);
        }

        // Simulate a crash after staging auxiliary files but before SQL commit.
        final previousMemory = await memory.read();
        final staged = await files.writeBytes(
          id: 'uncommitted',
          fileName: 'staged.txt',
          image: false,
          bytes: assetBytes,
        );
        await journal.write({
          'id': 'uncommitted-import',
          'files': [staged],
          'memory': previousMemory,
          'preferences': {'themeMode': 0},
        });
        await memory.write('Uncommitted memory');
        await prefs.setInt('themeMode', 1);
        await db.close();
        db = database = AppDatabase(NativeDatabase(databaseFile));
        service = FullBackupService(db, files, memory, prefs, journal);
        await service.recoverPending();
        expect(await memory.read(), previousMemory);
        expect(prefs.getInt('themeMode'), 0);
        expect(await files.readBytes(staged), isNull);
        expect(await journal.read(), isNull);
        expect(await db.select(db.conversations).get(), hasLength(2));
        container = openController(db);
        await container!.read(chatControllerProvider.future);
        await container!
            .read(chatControllerProvider.notifier)
            .selectConversation('legacy');
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container!,
          child: const MaterialApp(home: ChatPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('History survives upgrade'), findsOneWidget);
      expect(
        container!.read(chatControllerProvider).requireValue.isStreaming,
        isFalse,
      );
      expect(
        llm.calls,
        1,
        reason: 'Reopening must not automatically replay a model request',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container?.dispose();
      await database?.close();
      PathProviderPlatform.instance = originalPaths;
      final systemTemp = await Directory.systemTemp.resolveSymbolicLinks();
      final actualParent = await sandbox.parent.resolveSymbolicLinks();
      if (actualParent != systemTemp ||
          !sandbox.uri.pathSegments.any(
            (s) => s.startsWith('expert-chat-native-smoke-'),
          )) {
        throw StateError('Refusing to remove an unexpected test directory');
      }
      await sandbox.delete(recursive: true);
    }
  });
}
