import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/domain/chat/chat_skill_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = ChatSkillCatalog.factory();
  final writing = catalog.skillById('writing')!;
  const fallback = '全局预设';

  test('story, study, and ensemble inject no catalog prompt', () {
    final route = ChatSkillRoute(
      skill: writing,
      source: ChatSkillSource.model,
    );
    for (final mode in [
      ConversationMode.story,
      ConversationMode.study,
      ConversationMode.ensemble,
    ]) {
      expect(
        chatPresetPrompt(
          mode: mode,
          route: route,
          fallbackPrompt: fallback,
        ),
        isEmpty,
        reason: mode.name,
      );
    }
  });

  test('chat uses the routed writing prompt', () {
    expect(
      chatPresetPrompt(
        mode: ConversationMode.chat,
        route: ChatSkillRoute(
          skill: writing,
          source: ChatSkillSource.model,
        ),
        fallbackPrompt: fallback,
      ),
      writing.prompt.trim(),
    );
  });

  test('chat with a null route falls back to the global prompt', () {
    expect(
      chatPresetPrompt(
        mode: ConversationMode.chat,
        route: null,
        fallbackPrompt: fallback,
      ),
      fallback,
    );
  });

  test('chat with an empty skill prompt injects nothing', () {
    expect(
      chatPresetPrompt(
        mode: ConversationMode.chat,
        route: ChatSkillRoute(
          skill: writing.copyWith(prompt: '  '),
          source: ChatSkillSource.model,
        ),
        fallbackPrompt: fallback,
      ),
      isEmpty,
    );
  });
}
