import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/domain/chat/chat_skill_router.dart';
import 'package:expert_chat/domain/chat/request_context_builder.dart';
import 'package:expert_chat/domain/context/context_window_manager.dart';
import 'package:expert_chat/domain/story/story_generation_intent.dart';
import 'package:expert_chat/domain/story/story_prompt_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

const builder = RequestContextBuilder();
const noTrimming = ContextPrefs(enabled: false);
const route = ChatSkillRoute(
  skill: ChatSkill(
    id: 'translate',
    name: '翻译',
    when: '翻译',
    prompt: '  TRANSLATE  ',
  ),
  source: ChatSkillSource.prefix,
);
const notes = RequestContextNotes(
  project: 'PROJECT',
  tools: 'TOOLS',
  vision: 'VISION',
  image: 'IMAGE',
  memory: 'MEMORY',
  search: 'SEARCH',
  recovery: 'RECOVERY',
);

Conversation conversation({ConversationMode mode = ConversationMode.chat}) =>
    Conversation(
      mode: mode,
      messages: [
        ChatMessage(id: 'u1', role: MessageRole.user, content: 'old question'),
        ChatMessage(
          id: 'a1',
          role: MessageRole.assistant,
          content: 'old answer',
          parentId: 'u1',
          speakerName: '旅人',
          reasoning: 'previous reasoning',
        ),
        ChatMessage(
          id: 'u2',
          role: MessageRole.user,
          content: 'new question',
          parentId: 'a1',
        ),
        ChatMessage(
          id: 'pending',
          role: MessageRole.assistant,
          content: '',
          parentId: 'u2',
        ),
        ChatMessage(
          id: 'other-branch',
          role: MessageRole.assistant,
          content: 'do not send',
          parentId: 'u1',
        ),
      ],
      activeChildren: {'u1': 'a1'},
    );

List<String> contents(PreparedRequestContext value) =>
    value.messages.map((m) => m.content).toList();

void main() {
  test('work mode carries execution guidance even without tools', () {
    final result = builder.prepare(
      conversation: conversation().copyWith(workMode: true),
      assistantId: 'pending',
      contextPrefs: noTrimming,
      fallbackPrompt: '固定预设',
    );
    expect(contents(result).any((text) => text.contains('当前是工作模式')), isTrue);
    expect(contents(result), contains('固定预设'));
  });

  test(
    'chat preserves prefix order, active branch and search insertion point',
    () {
      final convo = conversation();
      final before = convo.toJson();
      final result = builder.prepare(
        conversation: convo,
        assistantId: 'pending',
        contextPrefs: noTrimming,
        notes: notes,
        chatRoute: route,
        fallbackPrompt: 'FALLBACK',
        studySystemPrompt: 'NOT STUDY',
      );
      expect(contents(result), [
        'PROJECT',
        'TOOLS',
        'VISION',
        'IMAGE',
        'TRANSLATE',
        'MEMORY',
        'old question',
        'old answer',
        'SEARCH',
        'new question',
        'RECOVERY',
      ]);
      expect(result.messages.first.role, MessageRole.system);
      // Stored reasoning is display-only and must not enter later requests.
      expect(result.messages[7].reasoningContent, isNull);
      expect(result.proseTask, isTrue);
      expect(result.worldInfoHits, isEmpty);
      expect(convo.toJson(), before);
      expect(() => result.messages.clear(), throwsUnsupportedError);
    },
  );

  test(
    'study excludes chat preset and places memory before the tutor prompt',
    () {
      final result = builder.prepare(
        conversation: conversation(mode: ConversationMode.study),
        assistantId: 'pending',
        contextPrefs: noTrimming,
        notes: notes,
        chatRoute: route,
        fallbackPrompt: 'FALLBACK',
        studySystemPrompt: 'STUDY',
      );
      expect(contents(result), [
        'PROJECT',
        'TOOLS',
        'VISION',
        'IMAGE',
        'MEMORY',
        'STUDY',
        'old question',
        'old answer',
        'SEARCH',
        'new question',
        'RECOVERY',
      ]);
      expect(result.proseTask, isFalse);
    },
  );

  test('chat fallback is trimmed and empty notes add no messages', () {
    final result = builder.prepare(
      conversation: conversation(),
      assistantId: 'pending',
      contextPrefs: noTrimming,
      fallbackPrompt: '  FALLBACK  ',
    );
    expect(contents(result), [
      'FALLBACK',
      'old question',
      'old answer',
      'new question',
    ]);
    expect(result.proseTask, isFalse);
  });

  test('story modes keep stable prefix and trailing action around history', () {
    final card = CharacterCard(name: '旅人');
    final world = WorldInfoEntry(title: '城镇', content: 'WORLD', alwaysOn: true);
    for (final mode in [ConversationMode.story, ConversationMode.ensemble]) {
      for (final intent in [
        StoryGenerationIntent.directProse,
        StoryGenerationIntent.revisePlan,
      ]) {
        final ensemble = mode == ConversationMode.ensemble;
        final convo = conversation(mode: mode).copyWith(
          localCast: ensemble ? [] : [card],
          outline: '抵达\n离开',
          plotCursor: 1,
        );
        final path = convo.activePath.where((m) => m.id != 'pending').toList();
        final prefix = const StoryPromptAssembler().buildSystemPrefix(
          globalSystemPrompt: '',
          character: ensemble ? card : null,
          cast: [card],
          speakingAs: ensemble ? card : null,
          worldInfoPool: [world],
          conversation: convo.copyWith(plotCursor: 0),
          historyPath: path,
          ensembleTurn: ensemble,
          directorMode: !ensemble,
          intent: intent,
        );
        final result = builder.prepare(
          conversation: convo,
          assistantId: 'pending',
          contextPrefs: noTrimming,
          notes: notes,
          chatRoute: route,
          fallbackPrompt: 'NOT CHAT',
          studySystemPrompt: 'NOT STUDY',
          story: StoryRequestContext(
            character: ensemble ? card : null,
            cast: [card],
            speakingAs: ensemble ? card : null,
            worldInfo: [world],
            promptPlotCursor: 0,
            intent: intent,
          ),
        );
        expect(contents(result), [
          'PROJECT',
          ...prefix.messages.map((m) => m.content),
          'MEMORY',
          'IMAGE',
          'VISION',
          'TOOLS',
          'old question',
          ensemble ? '【旅人】old answer' : 'old answer',
          'SEARCH',
          'new question',
          ...prefix.postHistoryMessages.map((m) => m.content),
          'RECOVERY',
        ]);
        expect(
          result.worldInfoHits.map((h) => h.id),
          prefix.worldInfoHits.map((h) => h.id),
        );
        expect(result.proseTask, intent.writesProse);
        expect(convo.plotCursor, 1);
      }
    }
  });

  test(
    'attachments preserve exact text and native-vision versus tool routing',
    () {
      final message = ChatMessage(
        role: MessageRole.user,
        content: 'QUESTION',
        attachments: [
          Attachment(
            name: 'note.txt',
            mimeType: 'text/plain',
            text: 'FILE',
            truncated: true,
          ),
          Attachment(
            name: 'pic.png',
            mimeType: 'image/png',
            imageBase64: 'AAAA',
          ),
        ],
      );
      final native = RequestContextBuilder.requestMessage(
        message,
        vision: true,
      );
      expect(native.content, '【文件：note.txt】\nFILE\n…（内容过长，已截断）\n\nQUESTION');
      expect(native.imageDataUrls, ['data:image/png;base64,AAAA']);
      final fallback = RequestContextBuilder.requestMessage(
        message,
        vision: false,
        imageToolAvailable: true,
      );
      expect(fallback.imageDataUrls, isEmpty);
      expect(fallback.content, contains('attachment_name 用此文件名'));
      expect(fallback.content, endsWith('QUESTION'));
    },
  );

  test(
    'budgeting happens after assembly and leaves the stored branch intact',
    () {
      final convo = conversation();
      final before = convo.toJson();
      final full = builder.prepare(
        conversation: convo,
        assistantId: 'pending',
        contextPrefs: noTrimming,
        notes: notes,
        chatRoute: route,
      );
      const prefs = ContextPrefs(
        contextWindowTokens: 4096,
        reservedOutputTokens: 3072,
        maxHistoryMessages: 2,
      );
      final expected = const ContextWindowManager().manage(
        full.messages,
        prefs,
      );
      final result = builder.prepare(
        conversation: convo,
        assistantId: 'pending',
        contextPrefs: prefs,
        notes: notes,
        chatRoute: route,
      );
      expect(
        result.messages.map((m) => m.toOpenAiJson()),
        expected.messages.map((m) => m.toOpenAiJson()),
      );
      expect(result.report.sentTokens, expected.report.sentTokens);
      expect(result.report.droppedMessages, greaterThan(0));
      expect(result.messages.any((m) => m.content == 'new question'), isTrue);
      expect(convo.toJson(), before);
    },
  );

  test(
    'oversized newest images report overflow only when budgeting is enabled',
    () {
      final convo = Conversation(
        messages: [
          ChatMessage(
            role: MessageRole.user,
            content: 'inspect',
            attachments: [
              for (var i = 0; i < 12; i++)
                Attachment(
                  name: '$i.png',
                  mimeType: 'image/png',
                  imageBase64: 'AAAA',
                ),
            ],
          ),
        ],
      );
      for (final enabled in [false, true]) {
        final result = builder.prepare(
          conversation: convo,
          assistantId: 'none',
          nativeVision: true,
          contextPrefs: ContextPrefs(
            enabled: enabled,
            contextWindowTokens: 4096,
            reservedOutputTokens: 3072,
          ),
        );
        expect(result.exceedsBudget, enabled);
        expect(result.messages.last.imageDataUrls.length, 12);
      }
    },
  );
}
