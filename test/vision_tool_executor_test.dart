import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/tools/vision_tool_executor.dart';
import 'package:expert_chat/domain/tools/vision_tools.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = LlmConfig(
  baseUrl: 'https://vision.example',
  apiKey: 'test',
  model: 'vision',
);
Attachment _image(String name) => Attachment(
  id: name,
  name: name,
  mimeType: 'image/png',
  imageBase64: 'AAAA',
);

class _Vision extends LlmProvider {
  final calls = <List<LlmRequestMessage>>[];
  Stream<ChatChunk> Function(CancelToken?) response = (_) =>
      Stream.fromIterable(const [
        ChatChunk(reasoningDelta: '不应出现在观察结果'),
        ChatChunk(contentDelta: '  看见'),
        ChatChunk(contentDelta: '文字  '),
      ]);
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) {
    expect(config, same(_config));
    expect(tools, isNull);
    expect(thinking, isNull);
    expect(reasoningEffort, isNull);
    expect(forceToolName, isNull);
    calls.add(messages);
    return response(cancelToken);
  }
}

Future<VisionToolResult> _execute(
  VisionToolExecutor executor, {
  String args = '{}',
  LlmConfig? config = _config,
  List<Attachment>? sources,
  CancelToken? token,
}) => executor.execute(
  call: ToolCall(index: 0, name: 'analyze_image', argumentsJson: args),
  config: config,
  sources: sources ?? [_image('first.png'), _image('last.png')],
  cancelToken: token ?? CancelToken(),
);

void main() {
  late _Vision provider;
  late List<SearchActivity> activities;
  late VisionToolExecutor executor;
  setUp(() {
    provider = _Vision();
    activities = [];
    executor = VisionToolExecutor(
      getProvider: () => provider,
      onActivity: activities.add,
      checkBudget: () => (allowed: true, reason: null),
    );
  });

  test(
    'tool selects named pixels and sends only the unchanged vision prompt and question',
    () async {
      final result = await _execute(
        executor,
        args: '{"filename":"FIRST.PNG","prompt":"  图上写了什么  "}',
      );
      expect(result.content, '【图片：first.png】\n看见文字');
      expect(result.error, isNull);
      final messages = provider.calls.single;
      expect(messages, hasLength(2));
      expect(messages.first.role, MessageRole.system);
      expect(
        messages.first.content,
        '你是视觉理解助手。只根据图片中可见内容作答，不要编造看不到的文字或物体。用简洁中文；若图中有文字请如实转录。',
      );
      expect(messages.last.content, '图上写了什么');
      expect(messages.last.imageDataUrls, ['data:image/png;base64,AAAA']);
      expect(activities.first.query, 'first.png');
      expect(activities.first.id, activities.last.id);
      expect(activities.last.status, SearchActivityStatus.done);
      expect(activities.last.resultCount, 1);
    },
  );

  test('malformed arguments use the last image and default question', () async {
    final result = await _execute(executor, args: '{');
    expect(result.content, startsWith('【图片：last.png】'));
    expect(provider.calls.single.last.content, VisionTools.defaultQuestion);
  });

  test(
    'missing configuration or image records rejection without consuming budget',
    () async {
      executor = VisionToolExecutor(
        getProvider: () => throw StateError('Must not request'),
        onActivity: activities.add,
        checkBudget: () => throw StateError('Must not charge'),
      );
      expect(
        (await _execute(executor, config: null)).content,
        '未配置视觉 API，无法识图。',
      );
      expect((await _execute(executor, sources: [])).content, '本轮没有可识图的图片附件。');
      final missing = await _execute(executor, args: '{"name":"missing.png"}');
      expect(missing.content, '找不到图片「missing.png」。可用： first.png、last.png');
      expect(missing.error, isNull);
      expect(activities, hasLength(6));
      expect(activities.last.error, '没有可识图附件');
      expect(activities.last.resultCount, 0);
    },
  );

  test(
    'budget rejection stops both entry points before accessing the provider',
    () async {
      var checks = 0;
      executor = VisionToolExecutor(
        getProvider: () => throw StateError('Must not request'),
        onActivity: activities.add,
        checkBudget: () {
          checks++;
          return (allowed: false, reason: '次数耗尽');
        },
      );
      final tool = await _execute(executor);
      final pre = await executor.analyze(
        config: _config,
        image: _image('pre.png'),
        question: '问题',
        cancelToken: CancelToken(),
      );
      expect(tool.content, '【图片：last.png】\n识图未执行：任务预算已用完。');
      expect(pre.content, '识图未执行：任务预算已用完。');
      expect(checks, 2);
      expect(activities.last.error, '次数耗尽');
    },
  );

  test('empty results retain tool and pre-analysis response formats', () async {
    provider.response = (_) =>
        Stream.value(const ChatChunk(reasoningDelta: '只有思考'));
    expect((await _execute(executor)).content, '识图服务没有返回可用内容。');
    final pre = await executor.analyze(
      config: _config,
      image: _image('pre.png'),
      question: '问题',
      cancelToken: CancelToken(),
    );
    expect(pre.content, '');
    expect(activities.last.status, SearchActivityStatus.failed);
    expect(activities.last.error, '空结果');
  });

  test(
    'provider failure preserves its error and a retry can complete',
    () async {
      final error = StateError('offline');
      provider.response = (_) => Stream.error(error);
      final failed = await _execute(executor);
      expect(failed.error, same(error));
      expect(failed.content, '【图片：last.png】\n识图失败：$error');
      expect(activities.last.error, contains('offline'));
      provider.response = (_) =>
          Stream.value(const ChatChunk(contentDelta: '重试结果'));
      expect((await _execute(executor)).content, '【图片：last.png】\n重试结果');
      expect(activities.last.status, SearchActivityStatus.done);
      expect(provider.calls, hasLength(2));
    },
  );

  test(
    'cancellation exceptions produce a failed activity without a scoped error',
    () async {
      final token = CancelToken();
      provider.response = (received) {
        expect(received, same(token));
        token.cancel();
        return Stream.error(token.cancelError!);
      };
      final result = await _execute(executor, token: token);
      expect(result.content, '【图片：last.png】\n识图已取消。');
      expect(result.error, isNull);
      expect(activities.last.error, '已取消');
      expect(activities.last.status, SearchActivityStatus.failed);
    },
  );

  test(
    'cancellation between chunks retains earlier content and ignores late content',
    () async {
      final token = CancelToken();
      provider.response = (_) async* {
        yield const ChatChunk(contentDelta: '已收到');
        token.cancel();
        yield const ChatChunk(contentDelta: '迟到');
      };
      final result = await _execute(executor, token: token);
      expect(result.content, '【图片：last.png】\n已收到');
      expect(result.error, isNull);
      // Preserve the existing behavior when cancellation does not throw.
      expect(activities.last.status, SearchActivityStatus.done);
    },
  );

  test(
    'source selection isolates the active branch and skips duplicate or assistant images',
    () {
      final first = _image('first.png');
      final last = _image('last.png');
      final conversation = Conversation(
        messages: [
          ChatMessage(
            id: 'u',
            role: MessageRole.user,
            content: '',
            attachments: [first],
          ),
          ChatMessage(
            id: 'a',
            parentId: 'u',
            role: MessageRole.assistant,
            content: '',
            attachments: [_image('generated.png')],
          ),
          ChatMessage(
            id: 'current',
            parentId: 'a',
            role: MessageRole.user,
            content: '',
            attachments: [first, last],
          ),
          ChatMessage(
            id: 'other',
            parentId: 'a',
            role: MessageRole.user,
            content: '',
            attachments: [_image('other.png')],
          ),
        ],
        activeChildren: {'a': 'current'},
      );
      final before = conversation.toJson();
      expect(VisionTools.attachmentsFor(conversation), [first, last]);
      expect(conversation.toJson(), before);
    },
  );
}
