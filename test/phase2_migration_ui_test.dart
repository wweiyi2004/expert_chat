import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/projects/projects_page.dart';
import 'package:expert_chat/features/library/generation_history_page.dart';
import 'package:expert_chat/features/settings/backup_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'widget_test.dart' show InMemoryRepo, FakeSettings;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'version 15 migration preserves existing messages and leaves project unclassified',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'expert-chat-v15-test-',
      );
      final file = File('${temp.path}/legacy.db');
      final fixture = AppDatabase(NativeDatabase(file));
      await DriftConversationRepository(fixture).saveConversation(
        Conversation(
          id: 'legacy',
          messages: [
            ChatMessage(id: 'message', role: MessageRole.user, content: '旧数据'),
          ],
        ),
      );
      // Derive the pre-feature schema, then reopen through the actual migration.
      await fixture.customStatement(
        'DROP INDEX idx_conversations_project_updated',
      );
      await fixture.customStatement(
        'ALTER TABLE conversations DROP COLUMN project_id',
      );
      for (final table in [
        'project_files',
        'generation_records',
        'backup_imports',
        'projects',
      ]) {
        await fixture.customStatement('DROP TABLE $table');
      }
      await fixture.customStatement('PRAGMA user_version = 15');
      await fixture.close();
      final upgraded = AppDatabase(NativeDatabase(file));
      try {
        final c = await DriftConversationRepository(
          upgraded,
        ).loadConversation('legacy');
        expect(c.projectId, isNull);
        expect(c.messages.single.content, '旧数据');
        expect(await upgraded.select(upgraded.projects).get(), isEmpty);
        expect(
          await upgraded.select(upgraded.generationRecords).get(),
          isEmpty,
        );
        expect(
          (await upgraded.customSelect('PRAGMA foreign_keys').getSingle())
              .data
              .values
              .single,
          1,
        );
      } finally {
        await upgraded.close();
        await temp.delete(recursive: true);
      }
    },
  );

  for (final page in [
    const ProjectsPage(),
    const GenerationHistoryPage(),
    const BackupPage(),
  ]) {
    testWidgets(
      '${page.runtimeType} renders on narrow phone without overflow',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            sharedPrefsProvider.overrideWithValue(prefs),
            conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
            settingsControllerProvider.overrideWith(FakeSettings.new),
          ],
        );
        await container.read(chatControllerProvider.future);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: page),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        await db.close();
      },
    );
  }
}
