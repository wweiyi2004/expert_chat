import 'dart:async';

import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/features/chat/chat_workspace_sidebar.dart';
import 'package:expert_chat/features/chat/controllers/conversation_sidebar_controller.dart';
import 'package:expert_chat/features/chat/jump_to_message.dart';
import 'package:expert_chat/features/chat/widgets/conversation_history_list.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart'
    show InMemoryRepo, FakeSettings, FakeLlmProvider, InMemoryLibraryFileStore;

SearchHit _hit(String id, {String message = ''}) =>
    SearchHit(convoId: id, messageId: message, snippet: 'match $id');

class _Repo extends InMemoryRepo {
  final queries = <String>[];
  final loads = <String, Completer<void>>{};
  final deleted = <String>[];
  bool failDelete = false;
  Future<List<SearchHit>> Function(String)? search;
  @override
  Future<List<SearchHit>> searchMessages(String query) {
    queries.add(query);
    return search?.call(query) ?? super.searchMessages(query);
  }

  @override
  Future<Conversation> loadConversation(String id) async {
    await loads[id]?.future;
    return super.loadConversation(id);
  }

  @override
  Future<void> deleteConversation(String id) async {
    deleted.add(id);
    if (failDelete) throw StateError('delete failed');
    await super.deleteConversation(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('search controller', () {
    testWidgets('debounce only sends the latest trimmed query', (tester) async {
      final calls = <String>[];
      final controller = ConversationSidebarController(
        search: (q) async {
          calls.add(q);
          return [_hit('a')];
        },
      );
      addTearDown(controller.dispose);
      controller.setQuery(' old ');
      await tester.pump(const Duration(milliseconds: 200));
      controller.setQuery(' new ');
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 50));
      expect(calls, ['new']);
      expect(controller.query, 'new');
      expect(controller.hits.single.convoId, 'a');
    });

    testWidgets(
      'old completion is invalidated immediately during new debounce',
      (tester) async {
        final old = Completer<List<SearchHit>>();
        final latest = Completer<List<SearchHit>>();
        final controller = ConversationSidebarController(
          search: (q) => q == 'old' ? old.future : latest.future,
        );
        addTearDown(controller.dispose);
        controller.setQuery('old');
        await tester.pump(const Duration(milliseconds: 250));
        controller.setQuery('new');
        old.complete([_hit('old')]);
        await tester.pump();
        expect(controller.hits, isEmpty);
        expect(controller.searching, isTrue);
        await tester.pump(const Duration(milliseconds: 250));
        latest.complete([_hit('new')]);
        await tester.pump();
        expect(controller.hits.single.convoId, 'new');
      },
    );

    testWidgets('late failures cannot overwrite successful newer results', (
      tester,
    ) async {
      final old = Completer<List<SearchHit>>();
      final controller = ConversationSidebarController(
        search: (q) => q == 'old' ? old.future : Future.value([_hit('new')]),
      );
      addTearDown(controller.dispose);
      controller.setQuery('old');
      await tester.pump(const Duration(milliseconds: 250));
      controller.setQuery('new');
      await tester.pump(const Duration(milliseconds: 250));
      old.completeError(StateError('old failure'));
      await tester.pump();
      expect(controller.hits.single.convoId, 'new');
      expect(controller.error, isNull);
    });

    testWidgets(
      'clearing query invalidates pending results and restores all modes',
      (tester) async {
        final gate = Completer<List<SearchHit>>();
        final controller = ConversationSidebarController(
          search: (_) => gate.future,
        );
        addTearDown(controller.dispose);
        controller.setQuery('query');
        await tester.pump(const Duration(milliseconds: 250));
        controller.setQuery('  ');
        gate.complete([_hit('old')]);
        await tester.pump();
        expect(controller.query, isEmpty);
        expect(controller.hits, isEmpty);
        expect(controller.searching, isFalse);
        expect(controller.matches(Conversation(id: 'any')), isTrue);
      },
    );

    testWidgets(
      'retry clears failure and mode filtering intersects search hits',
      (tester) async {
        var failed = true;
        final controller = ConversationSidebarController(
          search: (_) async {
            if (failed) throw StateError('offline');
            return [_hit('chat'), _hit('story')];
          },
        );
        addTearDown(controller.dispose);
        controller.setQuery('query');
        await tester.pump(const Duration(milliseconds: 250));
        expect(controller.error, isNotNull);
        failed = false;
        controller.retry();
        await tester.pump(const Duration(milliseconds: 1));
        controller.setMode(ConversationMode.chat);
        expect(controller.error, isNull);
        expect(controller.matches(Conversation(id: 'chat')), isTrue);
        expect(
          controller.matches(
            Conversation(id: 'story', mode: ConversationMode.story),
          ),
          isFalse,
        );
        expect(controller.matches(Conversation(id: 'missing')), isFalse);
      },
    );

    testWidgets(
      'dispose cancels debounce and ignores an in-flight completion',
      (tester) async {
        var requests = 0;
        final gate = Completer<List<SearchHit>>();
        ConversationSidebarController create() => ConversationSidebarController(
          search: (_) {
            requests++;
            return gate.future;
          },
        );
        final first = create()..setQuery('never');
        first.dispose();
        await tester.pump(const Duration(milliseconds: 250));
        expect(requests, 0);
        final second = create()..setQuery('started');
        await tester.pump(const Duration(milliseconds: 250));
        second.dispose();
        gate.complete([_hit('late')]);
        await tester.pump();
        expect(requests, 1);
        expect(second.hits, isEmpty);
      },
    );
  });

  group('sidebar integration', () {
    late _Repo repo;
    setUp(() {
      repo = _Repo()
        ..store = [
          Conversation(
            id: 'a',
            title: 'Alpha',
            messages: [
              ChatMessage(
                id: 'ma',
                role: MessageRole.user,
                content: 'alpha text',
              ),
            ],
          ),
          Conversation(
            id: 'b',
            title: 'Beta',
            messages: [
              ChatMessage(
                id: 'mb',
                role: MessageRole.user,
                content: 'beta text',
              ),
            ],
          ),
          Conversation(id: 'c', title: 'Story', mode: ConversationMode.story),
        ];
    });
    Future<void> drain(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<ProviderContainer> setup(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sharedPrefsProvider.overrideWithValue(prefs),
          libraryFileStoreProvider.overrideWithValue(
            InMemoryLibraryFileStore(),
          ),
          conversationRepositoryProvider.overrideWithValue(repo),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          llmProvider.overrideWithValue(FakeLlmProvider(const [])),
        ],
      );
      addTearDown(c.dispose);
      await c.read(chatControllerProvider.future);
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 288, child: ChatWorkspaceSidebar()),
            ),
          ),
        ),
      );
      await drain(tester);
      return c;
    }

    Finder row(String id) => find.byKey(ValueKey('conversation-row-$id'));
    ConversationHistoryList list(WidgetTester tester) => tester
        .widget<ConversationHistoryList>(find.byType(ConversationHistoryList));
    Future<void> query(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        text,
      );
      await tester.pump(const Duration(milliseconds: 250));
      await drain(tester);
    }

    Future<void> action(WidgetTester tester, String id, String label) async {
      await tester.tap(
        find.descendant(of: row(id), matching: find.byTooltip('会话操作')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('latest search controls rows and clear restores history', (
      tester,
    ) async {
      final old = Completer<List<SearchHit>>();
      repo.search = (q) => q == 'old' ? old.future : Future.value([_hit('b')]);
      await setup(tester);
      await query(tester, 'old');
      await query(tester, 'new');
      old.complete([_hit('a')]);
      await drain(tester);
      expect(row('a'), findsNothing);
      expect(row('b'), findsOneWidget);
      expect(find.text('匹配：match b'), findsOneWidget);
      await query(tester, '');
      expect(list(tester).visible, hasLength(3));
    });

    testWidgets(
      'search failure offers retry and mode filter remains independent',
      (tester) async {
        var fail = true;
        repo.search = (_) async {
          if (fail) throw StateError('offline');
          return [_hit('a'), _hit('c')];
        };
        await setup(tester);
        await query(tester, 'query');
        expect(find.text('搜索失败，请重试。'), findsOneWidget);
        fail = false;
        await tester.tap(find.text('重试搜索'));
        await drain(tester);
        await tester.tap(
          find.byKey(const ValueKey('conversation-mode-filter-chat')),
        );
        await drain(tester);
        expect(list(tester).visible.map((c) => c.id), ['a']);
      },
    );

    testWidgets('rename trims an inactive title and rejects an empty rename', (
      tester,
    ) async {
      final c = await setup(tester);
      await action(tester, 'b', '重命名');
      await tester.enterText(
        find.byKey(const ValueKey('conversation-rename-b')),
        '  Renamed  ',
      );
      await tester.tap(find.byTooltip('保存'));
      await drain(tester);
      expect(repo.store.firstWhere((c) => c.id == 'b').title, 'Renamed');
      expect(c.read(chatControllerProvider).requireValue.currentId, 'a');
      await action(tester, 'b', '重命名');
      await tester.enterText(
        find.byKey(const ValueKey('conversation-rename-b')),
        '   ',
      );
      await tester.tap(find.byTooltip('保存'));
      await drain(tester);
      expect(find.text('Renamed'), findsOneWidget);
    });

    testWidgets(
      'delete cancellation preserves rows and confirmation captures its original target',
      (tester) async {
        final c = await setup(tester);
        await action(tester, 'a', '删除');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(repo.deleted, isEmpty);
        await action(tester, 'a', '删除');
        await c.read(chatControllerProvider.notifier).selectConversation('b');
        await tester.tap(find.widgetWithText(FilledButton, '删除'));
        await tester.pumpAndSettle();
        expect(repo.deleted, ['a']);
        expect(row('a'), findsNothing);
        expect(list(tester).currentId, 'b');
      },
    );

    testWidgets('deleting the selected row selects a remaining conversation', (
      tester,
    ) async {
      await setup(tester);
      await action(tester, 'a', '删除');
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(list(tester).currentId, 'b');
      expect(row('a'), findsNothing);
    });

    testWidgets(
      'deleting the final conversation selects the fresh empty conversation',
      (tester) async {
        repo.store = [repo.store.first];
        await setup(tester);
        await action(tester, 'a', '删除');
        await tester.tap(find.widgetWithText(FilledButton, '删除'));
        await tester.pumpAndSettle();
        expect(list(tester).visible, hasLength(1));
        expect(list(tester).currentId, list(tester).visible.single.id);
        expect(list(tester).currentId, isNot('a'));
      },
    );

    testWidgets('failed deletion restores the row without invalid selection', (
      tester,
    ) async {
      repo.failDelete = true;
      final c = await setup(tester);
      await action(tester, 'a', '删除');
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(row('a'), findsOneWidget);
      expect(
        list(tester).visible.any((c) => c.id == list(tester).currentId),
        isTrue,
      );
      expect(
        c.read(chatControllerProvider).requireValue.error,
        contains('本地删除失败'),
      );
    });

    testWidgets(
      'search navigation waits for the target body before publishing jump',
      (tester) async {
        repo.search = (_) async => [_hit('b', message: 'mb')];
        final c = await setup(tester);
        repo.loads['b'] = Completer<void>();
        await query(tester, 'beta');
        await tester.tap(find.text('Beta'));
        await drain(tester);
        expect(c.read(pendingJumpMessageIdProvider), isNull);
        expect(c.read(chatControllerProvider).requireValue.currentId, 'a');
        repo.loads['b']!.complete();
        await drain(tester);
        expect(c.read(chatControllerProvider).requireValue.currentId, 'b');
        expect(c.read(pendingJumpMessageIdProvider), 'mb');
      },
    );

    testWidgets(
      'older slow selection cannot steal focus or jump after a newer row selection',
      (tester) async {
        final c = await setup(tester);
        final ctrl = c.read(chatControllerProvider.notifier);
        await ctrl.selectConversation('c');
        await ctrl.selectConversation('a');
        repo.loads['b'] = Completer<void>();
        await tester.tap(find.text('Beta'));
        await drain(tester);
        await tester.tap(find.text('Story'));
        await drain(tester);
        repo.loads['b']!.complete();
        await drain(tester);
        expect(list(tester).currentId, 'c');
        expect(c.read(pendingJumpMessageIdProvider), isNull);
      },
    );

    testWidgets('pending history load does not reopen chat after leaving it', (
      tester,
    ) async {
      final c = await setup(tester);
      repo.loads['b'] = Completer<void>();
      await tester.tap(find.text('Beta'));
      await drain(tester);
      await tester.tap(find.text('工具'));
      await drain(tester);
      expect(c.read(shellTabProvider), ShellTab.tools);
      repo.loads['b']!.complete();
      await drain(tester);
      expect(c.read(shellTabProvider), ShellTab.tools);
      expect(c.read(pendingJumpMessageIdProvider), isNull);
    });

    testWidgets('new conversation is not replaced by a pending history load', (
      tester,
    ) async {
      final c = await setup(tester);
      repo.loads['b'] = Completer<void>();
      await tester.tap(find.text('Beta'));
      await drain(tester);
      await tester.tap(find.byKey(const ValueKey('sidebar-new-chat')));
      await drain(tester);
      final fresh = c.read(chatControllerProvider).requireValue.currentId;
      repo.loads['b']!.complete();
      await drain(tester);
      expect(list(tester).currentId, fresh);
      expect(fresh, isNot('b'));
    });
  });
}
