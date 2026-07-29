import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/character_repository.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/data/world_info_repository.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:expert_chat/features/story/studio_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryConversationRepository implements ConversationRepository {
  _MemoryConversationRepository([List<Conversation>? seed])
    : _conversations = List.of(seed ?? const []);

  final List<Conversation> _conversations;

  @override
  Future<List<Conversation>> loadAll() async =>
      List.unmodifiable(_conversations);

  @override
  Future<void> saveAll(List<Conversation> conversations) async {
    _conversations
      ..clear()
      ..addAll(conversations);
  }

  @override
  Future<void> saveConversation(Conversation conversation) async {
    final index = _conversations.indexWhere(
      (candidate) => candidate.id == conversation.id,
    );
    if (index < 0) {
      _conversations.insert(0, conversation);
    } else {
      _conversations[index] = conversation;
    }
  }

  @override
  Future<void> deleteConversation(String id) async {
    _conversations.removeWhere((conversation) => conversation.id == id);
  }
}

class _MemoryCharacterRepository implements CharacterRepository {
  _MemoryCharacterRepository([List<CharacterCard>? seed])
    : _cards = List.of(seed ?? const []);

  final List<CharacterCard> _cards;

  @override
  Future<List<CharacterCard>> loadAll() async => List.unmodifiable(_cards);

  @override
  Future<CharacterCard?> getById(String id) async {
    for (final card in _cards) {
      if (card.id == id) return card;
    }
    return null;
  }

  @override
  Future<void> save(CharacterCard card) async {
    final i = _cards.indexWhere((c) => c.id == card.id);
    if (i < 0) {
      _cards.add(card);
    } else {
      _cards[i] = card;
    }
  }

  @override
  Future<void> delete(String id) async {
    _cards.removeWhere((c) => c.id == id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryWorldInfoRepository implements WorldInfoRepository {
  _MemoryWorldInfoRepository([List<WorldInfoEntry>? seed])
    : _entries = List.of(seed ?? const []);

  final List<WorldInfoEntry> _entries;

  @override
  Future<List<WorldInfoEntry>> loadAll() async => List.unmodifiable(_entries);

  @override
  Future<List<WorldInfoEntry>> loadByIds(Iterable<String> ids) async {
    final wanted = ids.toSet();
    return [
      for (final e in _entries)
        if (wanted.contains(e.id)) e,
    ];
  }

  @override
  Future<void> save(WorldInfoEntry entry) async {
    final i = _entries.indexWhere((e) => e.id == entry.id);
    if (i < 0) {
      _entries.add(entry);
    } else {
      _entries[i] = entry;
    }
  }

  @override
  Future<void> delete(String id) async {
    _entries.removeWhere((e) => e.id == id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('创作首页展示开始路径与素材入口', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(
            _MemoryConversationRepository(),
          ),
          characterRepositoryProvider.overrideWithValue(
            _MemoryCharacterRepository(),
          ),
          worldInfoRepositoryProvider.overrideWithValue(
            _MemoryWorldInfoRepository(),
          ),
        ],
        child: const MaterialApp(home: StudioPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('studio-start-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('studio-start-director')), findsOneWidget);
    expect(find.byKey(const ValueKey('studio-start-ensemble')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('studio-start-pick-character')),
      findsOneWidget,
    );
    expect(find.text('导演故事'), findsOneWidget);
    expect(find.text('角色大乱斗'), findsOneWidget);
    expect(find.text('选角色开聊'), findsOneWidget);
    expect(find.byKey(const ValueKey('studio-new-character')), findsOneWidget);
    expect(find.byKey(const ValueKey('studio-new-world')), findsOneWidget);
  });

  testWidgets('选角色开聊切到角色 Tab，点世界书素材进世界书 Tab', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(
            _MemoryConversationRepository(),
          ),
          characterRepositoryProvider.overrideWithValue(
            _MemoryCharacterRepository([
              CharacterCard(name: '阿宁', description: '图书馆值夜的研究生'),
            ]),
          ),
          worldInfoRepositoryProvider.overrideWithValue(
            _MemoryWorldInfoRepository(),
          ),
        ],
        child: const MaterialApp(home: StudioPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('studio-start-pick-character')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('character-library-list')),
      findsOneWidget,
    );
    expect(find.text('阿宁'), findsOneWidget);
    expect(find.text('开聊'), findsOneWidget);

    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('studio-asset-world')));
    await tester.pumpAndSettle();
    expect(find.text('还没有世界书条目'), findsOneWidget);
  });

  testWidgets('角色空状态提供导演故事导流', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(
            _MemoryConversationRepository(),
          ),
          characterRepositoryProvider.overrideWithValue(
            _MemoryCharacterRepository(),
          ),
          worldInfoRepositoryProvider.overrideWithValue(
            _MemoryWorldInfoRepository(),
          ),
        ],
        child: const MaterialApp(home: StudioPage(initialTab: 1)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有角色卡'), findsOneWidget);
    expect(find.text('创建第一个角色'), findsOneWidget);
    expect(find.text('或直接开导演故事'), findsOneWidget);
  });

  testWidgets('创作首页展示最近作品并可直接回到对应会话', (tester) async {
    final recentStory = Conversation(
      id: 'recent-story',
      title: '雾港夜车',
      mode: ConversationMode.story,
      localCast: [
        CharacterCard(name: '林澈'),
        CharacterCard(name: '顾舟'),
      ],
      outline: '- 夜车驶入雾港\n- 乘客发现死亡车票\n- 船长揭开旧案',
      plotCursor: 1,
      targetTotalChars: 80000,
      updatedAt: DateTime.now(),
    );
    final olderEnsemble = Conversation(
      id: 'older-ensemble',
      title: '雨夜茶馆',
      mode: ConversationMode.ensemble,
      participantIds: const ['a', 'b', 'c'],
      updatedAt: DateTime.now().subtract(const Duration(days: 1)),
      messages: [
        ChatMessage(
          role: MessageRole.assistant,
          content: '三个人在茶馆坐下。',
          speakerName: '旁白',
        ),
      ],
    );
    final conversations = _MemoryConversationRepository([
      recentStory,
      olderEnsemble,
      Conversation(title: '普通问题'),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(conversations),
          characterRepositoryProvider.overrideWithValue(
            _MemoryCharacterRepository(),
          ),
          worldInfoRepositoryProvider.overrideWithValue(
            _MemoryWorldInfoRepository(),
          ),
        ],
        child: const MaterialApp(home: StudioPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('继续创作'), findsOneWidget);
    expect(find.text('雾港夜车'), findsOneWidget);
    expect(find.text('雨夜茶馆'), findsOneWidget);
    expect(find.textContaining('1/3 个情节'), findsOneWidget);
    expect(find.textContaining('目标 8万 字'), findsOneWidget);
    expect(find.text('普通问题'), findsNothing);

    final context = tester.element(find.byType(StudioPage));
    final container = ProviderScope.containerOf(context);
    container.read(shellTabProvider.notifier).set(ShellTab.studio);

    await tester.tap(find.byKey(const ValueKey('studio-recent-recent-story')));
    await tester.pump();

    expect(
      container.read(chatControllerProvider).requireValue.currentId,
      'recent-story',
    );
    expect(container.read(shellTabProvider), ShellTab.chat);
  });
}
