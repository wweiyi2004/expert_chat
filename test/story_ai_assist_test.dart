import 'package:dio/dio.dart' show CancelToken;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/story/story_ai_assist.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLlmProvider implements LlmProvider {
  _FakeLlmProvider(this.response);

  final String response;
  final List<List<LlmRequestMessage>> calls = [];
  bool? thinking;
  CancelToken? cancelToken;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  }) async* {
    calls.add(List.of(messages));
    this.thinking = thinking;
    this.cancelToken = cancelToken;
    final midpoint = response.length ~/ 2;
    yield ChatChunk(contentDelta: response.substring(0, midpoint));
    yield ChatChunk(contentDelta: response.substring(midpoint));
  }
}

const _readyConfig = LlmConfig(
  baseUrl: 'https://example.com',
  apiKey: 'test-key',
  model: 'test-model',
);

void main() {
  group('extractJsonObject', () {
    test('parses plain json', () {
      final m = extractJsonObjectForTest('{"name":"林晚","description":"剑客"}');
      expect(m?['name'], '林晚');
      expect(m?['description'], '剑客');
    });

    test('strips markdown fences', () {
      final m = extractJsonObjectForTest('''
```json
{"title":"王都","keys":["王都","帝都"],"alwaysOn":false}
```
''');
      expect(m?['title'], '王都');
      expect(m?['keys'], isA<List>());
    });

    test('finds object inside prose', () {
      final m = extractJsonObjectForTest(
        '好的，如下：{"name":"阿宁","personality":"温柔"} 完毕',
      );
      expect(m?['name'], '阿宁');
    });
  });

  group('drafts', () {
    test('CharacterCardDraft.fromJsonMap', () {
      final d = CharacterCardDraft.fromJsonMap({
        'name': '  林晚  ',
        'firstMes': '你好',
      });
      expect(d?.name, '林晚');
      expect(d?.firstMes, '你好');
      final card = d!.toCard();
      expect(card.name, '林晚');
      expect(card.firstMes, '你好');
    });

    test('WorldInfoDraft.fromJsonMap keys list', () {
      final d = WorldInfoDraft.fromJsonMap({
        'title': '魔法学',
        'keys': ['魔法', '法术'],
        'content': '……',
        'alwaysOn': true,
        'priority': 10,
      });
      expect(d?.keys, ['魔法', '法术']);
      expect(d?.alwaysOn, isTrue);
      final entry = d!.toEntry();
      expect(entry.title, '魔法学');
      expect(entry.priority, 10);
    });

    test(
      'DirectorStoryDraft normalizes array outline and character aliases',
      () {
        final draft = DirectorStoryDraft.fromJsonMap({
          'storyTitle': '雾港来信',
          'plot': [
            '陌生来信抵达',
            {'title': '追踪', 'summary': '众人前往废弃灯塔'},
            3,
          ],
          'author_note': '用户负责导演。',
          'character_cards': [
            {'name': ' 林澈 ', 'first_mes': '谁寄来的？', 'system_prompt': '保持谨慎。'},
            'not an object',
          ],
        });

        expect(draft?.title, '雾港来信');
        expect(draft?.outline, '- 陌生来信抵达\n- 追踪：众人前往废弃灯塔\n- 3');
        expect(draft?.authorNote, '用户负责导演。');
        expect(draft?.characters, hasLength(1));
        expect(draft?.characters.single.name, '林澈');
        expect(draft?.characters.single.firstMes, '谁寄来的？');
        expect(draft?.characters.single.systemPrompt, '保持谨慎。');
      },
    );
  });

  group('generateDirectorStory', () {
    test('generates cast and outline from a premise', () async {
      final llm = _FakeLlmProvider('''
{
  "title": "最后一班地铁",
  "outline": "- 末班车驶入不存在的车站\\n- 乘客发现彼此共享同一段记忆",
  "authorNote": "AI 扮演全部角色，用户是导演。",
  "characters": [
    {
      "name": "周岚",
      "description": "夜班医生。",
      "personality": "冷静，害怕失去控制。",
      "scenario": "被困在末班地铁。",
      "firstMes": "这不是我们该到的站。",
      "exampleDialogs": "导演：观察站台。\\n周岚：先别下车。",
      "systemPrompt": "保持克制且善于观察。"
    }
  ]
}
''');
      final cancelToken = CancelToken();
      final seed = DirectorStoryDraft(
        title: '旧标题',
        outline: '- 旧情节',
        characters: const [CharacterCardDraft(name: '旧角色')],
      );

      final draft = await StoryAiAssist(llm).generateDirectorStory(
        config: _readyConfig,
        premise: '末班地铁驶入一个不存在的车站',
        style: '悬疑',
        length: '短篇',
        seed: seed,
        cancelToken: cancelToken,
      );

      expect(draft.title, '最后一班地铁');
      expect(draft.outline, contains('共享同一段记忆'));
      expect(draft.characters.single.name, '周岚');
      expect(draft.characters.single.systemPrompt, '保持克制且善于观察。');
      expect(llm.thinking, isFalse);
      expect(llm.cancelToken, same(cancelToken));
      expect(llm.calls, hasLength(1));
      expect(llm.calls.single.first.role, MessageRole.system);
      expect(llm.calls.single.first.content, contains('"characters"'));
      final userPrompt = llm.calls.single.last.content;
      expect(userPrompt, contains('末班地铁驶入一个不存在的车站'));
      expect(userPrompt, contains('文风：悬疑'));
      expect(userPrompt, contains('篇幅：短篇'));
      expect(userPrompt, contains('"旧角色"'));
    });

    test('uses safe title and author-note defaults', () async {
      final llm = _FakeLlmProvider('''
{"title":"","outline":["开始","转折"],"characters":[{"name":"旅人"}]}
''');
      final draft = await StoryAiAssist(
        llm,
      ).generateDirectorStory(config: _readyConfig, premise: '一个旅人醒来后发现城市没有影子');

      expect(draft.title, '一个旅人醒来后发现城市没有影子');
      expect(draft.outline, '- 开始\n- 转折');
      expect(draft.authorNote, DirectorStoryDraft.defaultAuthorNote);
    });

    test('rejects incomplete model output', () async {
      final llm = _FakeLlmProvider('{"title":"只有标题","characters":[]}');

      await expectLater(
        StoryAiAssist(
          llm,
        ).generateDirectorStory(config: _readyConfig, premise: '任意情节'),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('格式不完整'),
          ),
        ),
      );
    });

    test('rejects an empty premise before calling the provider', () async {
      final llm = _FakeLlmProvider('{}');

      await expectLater(
        StoryAiAssist(
          llm,
        ).generateDirectorStory(config: _readyConfig, premise: '   '),
        throwsA(isA<Exception>()),
      );
      expect(llm.calls, isEmpty);
    });
  });

  group('draft parsing tolerates structured model output', () {
    test('joins array-valued character fields instead of dropping them', () {
      final draft = CharacterCardDraft.fromJsonMap({
        'name': '林澈',
        'exampleDialogs': ['导演：开场如何？', '林澈：从雨夜开始。'],
      });

      expect(draft, isNotNull);
      expect(draft!.exampleDialogs, contains('导演：开场如何？'));
      expect(draft.exampleDialogs, contains('林澈：从雨夜开始。'));
    });

    test('outline bullets keep leading minus signs and decimals', () {
      final draft = DirectorStoryDraft.fromJsonMap({
        'title': '雪镇',
        'outline': ['-5℃的雪夜，男主抵达小镇', '3.5小时后，桥被封锁', '1. 开场：车站相遇'],
        'characters': [
          {'name': '男主'},
        ],
      });

      expect(draft, isNotNull);
      expect(draft!.outline, contains('-5℃的雪夜'));
      expect(draft.outline, contains('3.5小时后'));
      expect(draft.outline, contains('开场：车站相遇'));
      expect(draft.outline, isNot(contains('1. 开场')));
    });
  });
}
