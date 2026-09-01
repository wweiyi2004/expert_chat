import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/character_repository.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/data/world_info_repository.dart';
import 'package:expert_chat/features/story/story_panel.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryConversationRepository
    with ConversationRepositoryViaLoadAll
    implements ConversationRepository {
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

/// Host that re-uses one [StoryPanelBody] instance across conversations,
/// mirroring the embedded side pane: the widget stays alive while
/// `conversationId` changes.
class _PanelSwitchHost extends StatefulWidget {
  const _PanelSwitchHost();

  @override
  State<_PanelSwitchHost> createState() => _PanelSwitchHostState();
}

class _PanelSwitchHostState extends State<_PanelSwitchHost> {
  String _conversationId = 'convo-a';

  void switchTo(String id) => setState(() => _conversationId = id);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: StoryPanelBody(conversationId: _conversationId, embedded: true),
      ),
    );
  }
}

void main() {
  test('clearing author note preserves the original story premise', () {
    const previous =
        'AI 扮演全部角色，用户是导演。\n\n'
        '【故事原始情节】（核心基调与事件不可擅自改写）\n'
        '夜车永远无法抵达终点。';

    final protected = protectStoryAuthorNote(previous: previous, edited: '');

    expect(protected, contains('【故事原始情节】'));
    expect(protected, contains('夜车永远无法抵达终点'));
  });

  test('new text is appended without dropping protected setup blocks', () {
    const previous =
        '【硬性创作约束】（不可违背）\n禁止超自然\n\n'
        '【故事原始情节】（核心基调与事件不可擅自改写）\n现实悬疑。';

    final protected = protectStoryAuthorNote(
      previous: previous,
      edited: '节奏再慢一些',
    );

    expect(protected, contains('禁止超自然'));
    expect(protected, contains('现实悬疑'));
    expect(protected, contains('【情节面板补充】\n节奏再慢一些'));
  });

  test('keeping one protected header does not erase the other', () {
    const previous =
        '【硬性创作约束】（不可违背）\n禁止超自然\n\n'
        '【故事原始情节】（核心基调与事件不可擅自改写）\n现实悬疑。';

    final protected = protectStoryAuthorNote(
      previous: previous,
      edited: '【硬性创作约束】（不可违背）\n禁止超自然；禁止巧合破案',
    );

    expect(protected, contains('禁止巧合破案'));
    expect(protected, contains('【故事原始情节】'));
    expect(protected, contains('现实悬疑'));
  });

  testWidgets('switching sessions flushes the pending debounced edit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _MemoryConversationRepository([
      Conversation(id: 'convo-a', title: '会话 A', mode: ConversationMode.story),
      Conversation(id: 'convo-b', title: '会话 B', mode: ConversationMode.story),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(repo),
          characterRepositoryProvider.overrideWithValue(
            _MemoryCharacterRepository(),
          ),
          worldInfoRepositoryProvider.overrideWithValue(
            _MemoryWorldInfoRepository(),
          ),
        ],
        child: const _PanelSwitchHost(),
      ),
    );
    await tester.pumpAndSettle();

    // Type into session A's director note; the 450ms debounce has not fired.
    await tester.enterText(find.byType(TextField).last, '雨中追逐');

    // Switch to session B before the debounce window elapses.
    tester
        .state<_PanelSwitchHostState>(find.byType(_PanelSwitchHost))
        .switchTo('convo-b');
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(_PanelSwitchHost)),
    );
    final state = container.read(chatControllerProvider).requireValue;
    final a = state.conversations.firstWhere((c) => c.id == 'convo-a');
    final b = state.conversations.firstWhere((c) => c.id == 'convo-b');
    // The old session must have received its pending edit…
    expect(a.authorNote, contains('雨中追逐'));
    // …and the new session must not have been clobbered with it.
    expect(b.authorNote, isNot(contains('雨中追逐')));
    expect(b.authorNote, isEmpty);

    // No leftover debounce timer may fire against the disposed controllers.
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a disabled world-info entry can still be unchecked', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final convo = Conversation(
      id: 'convo-a',
      title: '会话 A',
      mode: ConversationMode.story,
      worldInfoIds: const ['wi-selected'],
    );
    final worldRepo = _MemoryWorldInfoRepository([
      WorldInfoEntry(id: 'wi-selected', title: '已选且禁用', enabled: false),
      WorldInfoEntry(id: 'wi-fresh', title: '未选且禁用', enabled: false),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(
            _MemoryConversationRepository([convo]),
          ),
          characterRepositoryProvider.overrideWithValue(
            _MemoryCharacterRepository(),
          ),
          worldInfoRepositoryProvider.overrideWithValue(worldRepo),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: StoryPanelBody(conversationId: 'convo-a', embedded: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A disabled entry that is already selected must stay toggleable so the
    // session can drop it again; only the checkbox must not be greyed out.
    final selectedTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, '已选且禁用'),
    );
    expect(selectedTile.value, isTrue);
    expect(selectedTile.onChanged, isNotNull);

    // A disabled entry that is not selected stays uncheckable.
    final freshTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, '未选且禁用'),
    );
    expect(freshTile.value, isFalse);
    expect(freshTile.onChanged, isNull);

    await tester.tap(find.widgetWithText(CheckboxListTile, '已选且禁用'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // debounce fires

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StoryPanelBody)),
    );
    final saved = container
        .read(chatControllerProvider)
        .requireValue
        .conversations
        .first;
    expect(saved.worldInfoIds, isEmpty);
  });

  testWidgets('保存到角色库 updates a same-name card instead of duplicating', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final charRepo = _MemoryCharacterRepository([
      CharacterCard(name: '阿宁', description: '旧版描述'),
    ]);
    final convo = Conversation(
      id: 'convo-a',
      title: '会话 A',
      mode: ConversationMode.story,
      localCast: [CharacterCard(name: '阿宁', description: '新版描述')],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(
            _MemoryConversationRepository([convo]),
          ),
          characterRepositoryProvider.overrideWithValue(charRepo),
          worldInfoRepositoryProvider.overrideWithValue(
            _MemoryWorldInfoRepository(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: StoryPanelBody(conversationId: 'convo-a', embedded: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('阿宁')); // expand the local-cast card
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存到角色库'));
    await tester.pumpAndSettle();

    final cards = await charRepo.loadAll();
    // Same name → the library row is updated, not duplicated.
    expect(cards, hasLength(1));
    expect(cards.single.name, '阿宁');
    expect(cards.single.description, '新版描述');
  });

  testWidgets('保存到角色库 adds a card when the name is new', (tester) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final charRepo = _MemoryCharacterRepository();
    final convo = Conversation(
      id: 'convo-a',
      title: '会话 A',
      mode: ConversationMode.story,
      localCast: [CharacterCard(name: '林澈', description: '守夜人')],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(
            _MemoryConversationRepository([convo]),
          ),
          characterRepositoryProvider.overrideWithValue(charRepo),
          worldInfoRepositoryProvider.overrideWithValue(
            _MemoryWorldInfoRepository(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: StoryPanelBody(conversationId: 'convo-a', embedded: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('林澈'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存到角色库'));
    await tester.pumpAndSettle();

    final cards = await charRepo.loadAll();
    expect(cards, hasLength(1));
    expect(cards.single.name, '林澈');
    expect(cards.single.description, '守夜人');
  });
}
