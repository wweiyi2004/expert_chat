import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/domain/research/research_copilot_service.dart';
import 'package:expert_chat/domain/story/story_prompt_assembler.dart';
import 'package:expert_chat/domain/study/study_prompt_assembler.dart';
import 'package:expert_chat/domain/study/tutor_style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mode prompt contracts', () {
    test('every built-in chat skill keeps visible output in content', () {
      final catalog = ChatSkillCatalog.factory();

      for (final skill in catalog.skills) {
        expect(
          skill.prompt,
          contains('content'),
          reason:
              '${skill.id} must keep its final result out of reasoning-only output',
        );
        expect(skill.prompt, contains('reasoning'));
      }

      expect(catalog.skillById('general')!.prompt, contains('R18'));
      expect(catalog.skillById('writing')!.prompt, contains('无需自动淡出'));
      expect(catalog.skillById('writing')!.prompt, contains('未成年人'));
      expect(catalog.skillById('writing')!.prompt, contains('真实人物'));
      expect(catalog.skillById('writing')!.prompt, contains('不得自行补写年龄'));
      expect(catalog.skillById('writing')!.prompt, contains('不要询问'));
      expect(catalog.skillById('translate')!.prompt, contains('不因题材自动删减'));
      expect(catalog.skillById('summarize')!.prompt, contains('中性、准确地总结'));
    });

    test('all story sub-modes share the adult text boundary', () {
      final cast = [
        CharacterCard(name: '林晚', description: '明确为 25 岁的虚构角色'),
        CharacterCard(name: '沈砦', description: '明确为 27 岁的虚构角色'),
      ];
      final conversation = Conversation(mode: ConversationMode.story);
      final assembler = const StoryPromptAssembler();

      String joined({bool ensemble = false, bool director = false}) {
        final build = assembler.buildSystemPrefix(
          globalSystemPrompt: '',
          character: cast.first,
          cast: cast,
          speakingAs: ensemble ? cast.first : null,
          worldInfoPool: const [],
          conversation: conversation,
          historyPath: const [],
          ensembleTurn: ensemble,
          directorMode: director,
        );
        return build.messages.map((message) => message.content).join('\n');
      }

      final characterPrompt = joined();
      final ensemblePrompt = joined(ensemble: true);
      final directorPrompt = joined(director: true);

      expect(characterPrompt, contains('单角色故事模式'));
      expect(ensemblePrompt, contains('多角色同台'));
      expect(directorPrompt, contains('导演故事模式'));
      for (final prompt in [characterPrompt, ensemblePrompt, directorPrompt]) {
        expect(prompt, contains('【允许范围】'));
        expect(prompt, contains('“R18”'));
        expect(prompt, contains('无需自动淡出'));
        expect(prompt, contains('未成年人'));
        expect(prompt, contains('年龄或同意状态未说明'));
        expect(prompt, contains('真实人物'));
        expect(prompt, contains('无法有效同意'));
        expect(prompt, contains('不得自行补写年龄'));
        expect(prompt, contains('SFW'));
        expect(prompt, contains('content'));
        expect(prompt, contains('reasoning'));
      }
    });

    test('study mode treats adult subjects academically', () {
      final prompt = const StudyPromptAssembler().tutorSystem(
        style: TutorStyle.mixed,
        topic: '成人文学批评',
      );

      expect(prompt, contains('成人文学、性学、性健康或 R18 作品'));
      expect(prompt, contains('不因成人题材自动回避'));
      expect(prompt, contains('不将学习回答转成'));
      expect(prompt, contains('content'));
      expect(prompt, contains('reasoning'));
    });

    test('research mode treats R18 material as terminal data', () {
      const prompt = ResearchCopilotService.systemPrompt;

      expect(prompt, contains('成人/R18 主题'));
      expect(prompt, contains('题材本身不改变命令风险等级'));
      expect(prompt, contains('严格合法的 JSON 对象'));
      expect(prompt, contains('content'));
      expect(prompt, contains('reasoning'));
    });
  });
}
