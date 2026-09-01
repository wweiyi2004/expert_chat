import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadySettings extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState();
}

class _TrackingRepo
    with ConversationRepositoryViaLoadAll
    implements ConversationRepository {
  _TrackingRepo(this.store);

  final List<Conversation> store;
  int loadAllCalls = 0;
  int loadSummariesCalls = 0;
  final loadedIds = <String>[];

  @override
  Future<List<Conversation>> loadAll() async {
    loadAllCalls++;
    return List.of(store);
  }

  @override
  Future<List<ConversationSummary>> loadSummaries() async {
    loadSummariesCalls++;
    return super.loadSummaries();
  }

  @override
  Future<Conversation> loadConversation(String id) async {
    loadedIds.add(id);
    return super.loadConversation(id);
  }

  @override
  Future<void> saveAll(List<Conversation> conversations) async {
    store
      ..clear()
      ..addAll(conversations);
  }

  @override
  Future<void> saveConversation(Conversation conversation) async {
    final idx = store.indexWhere((c) => c.id == conversation.id);
    if (idx >= 0) {
      store[idx] = conversation;
    } else {
      store.insert(0, conversation);
    }
  }

  @override
  Future<void> deleteConversation(String id) async {
    store.removeWhere((c) => c.id == id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ChatController loads summaries then the current conversation only', () async {
    SharedPreferences.setMockInitialValues({});
    final older = Conversation(
      id: 'old',
      title: '旧会话',
      messages: [
        ChatMessage(id: 'old-u', role: MessageRole.user, content: 'old text'),
      ],
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    final newer = Conversation(
      id: 'new',
      title: '新会话',
      messages: [
        ChatMessage(id: 'new-u', role: MessageRole.user, content: 'new text'),
      ],
      updatedAt: DateTime.utc(2026, 2, 1),
    );
    final repo = _TrackingRepo([newer, older]);
    final container = ProviderContainer(
      overrides: [
        conversationRepositoryProvider.overrideWithValue(repo),
        settingsControllerProvider.overrideWith(_ReadySettings.new),
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(chatControllerProvider.future);
    expect(repo.loadSummariesCalls, 1);
    expect(repo.loadedIds, ['new']);
    expect(state.currentId, 'new');
    expect(state.current?.messages.single.content, 'new text');
    expect(state.current?.messagesLoaded, isTrue);

    final placeholder = state.conversations.firstWhere((c) => c.id == 'old');
    expect(placeholder.messagesLoaded, isFalse);
    expect(placeholder.messages, isEmpty);

    await container.read(chatControllerProvider.notifier).selectConversation('old');
    final after = container.read(chatControllerProvider).value!;
    expect(repo.loadedIds, ['new', 'old']);
    expect(after.currentId, 'old');
    expect(after.current?.messagesLoaded, isTrue);
    expect(after.current?.messages.single.content, 'old text');
  });

  test('deleting an unloaded conversation does not load its messages', () async {
    SharedPreferences.setMockInitialValues({});
    final keep = Conversation(
      id: 'keep',
      title: '留下',
      messages: [
        ChatMessage(id: 'k1', role: MessageRole.user, content: 'keep me'),
      ],
      updatedAt: DateTime.utc(2026, 2, 1),
    );
    final drop = Conversation(
      id: 'drop',
      title: '删除',
      messages: [
        ChatMessage(id: 'd1', role: MessageRole.user, content: 'drop me'),
      ],
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    final repo = _TrackingRepo([keep, drop]);
    final container = ProviderContainer(
      overrides: [
        conversationRepositoryProvider.overrideWithValue(repo),
        settingsControllerProvider.overrideWith(_ReadySettings.new),
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.future);
    expect(repo.loadedIds, ['keep']);

    await container
        .read(chatControllerProvider.notifier)
        .deleteConversation('drop');
    final state = container.read(chatControllerProvider).value!;
    expect(state.conversations.map((c) => c.id), ['keep']);
    expect(repo.loadedIds, ['keep']);
    expect(repo.store.map((c) => c.id), ['keep']);
  });
}
