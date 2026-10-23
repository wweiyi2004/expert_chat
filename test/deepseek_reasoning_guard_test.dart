import 'dart:async';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/deepseek_reasoning_guard.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _Request {
  _Request(
    this.config,
    this.messages,
    this.thinking,
    this.cancelToken,
    this.tools,
  );
  final LlmConfig config;
  final List<LlmRequestMessage> messages;
  final bool? thinking;
  final CancelToken? cancelToken;
  final List<ToolSpec>? tools;
}

class _Provider implements LlmProvider {
  _Provider(this.respond);
  final Stream<ChatChunk> Function(_Request, int) respond;
  final requests = <_Request>[];
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
    final request = _Request(config, messages, thinking, cancelToken, tools);
    requests.add(request);
    return respond(request, requests.length);
  }
}

const _config = LlmConfig(
  baseUrl: 'https://api.deepseek.com',
  apiKey: 'test',
  model: 'deepseek-v4-flash',
);
const _messages = [LlmRequestMessage(role: MessageRole.user, content: '请回答问题')];

void main() {
  test(
    'work requests bypass reasoning caps and retries without changing thinking',
    () async {
      final provider = _Provider((_, _) async* {
        yield ChatChunk(reasoningDelta: List.filled(20000, '想').join());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        yield const ChatChunk(contentDelta: '开始执行', finishReason: 'stop');
      });
      final config = _config
          .copyWith(reasoningGuardEnabled: false)
          .copyWith(model: 'deepseek-v4.1-flash');
      final chunks =
          await DeepSeekReasoningGuard(
                delegate: provider,
                maxReasoningChars: 1,
                reasoningTimeout: const Duration(milliseconds: 1),
                maxRecoveryChars: 1,
                recoveryTimeout: const Duration(milliseconds: 1),
              )
              .streamChat(config: config, messages: _messages, thinking: true)
              .toList();
      expect(provider.requests, hasLength(1));
      expect(provider.requests.single.thinking, true);
      expect(provider.requests.single.messages, same(_messages));
      expect(chunks.last.contentDelta, '开始执行');
      expect(config.reasoningGuardEnabled, false);
    },
  );
  test(
    'prose constraints preserve custom instructions and complete long answers',
    () async {
      final prose = List.filled(200, '正文内容。').join();
      final messages = [
        const LlmRequestMessage(
          role: MessageRole.system,
          content: '保留术语表和用户文风。',
        ),
        const LlmRequestMessage(role: MessageRole.user, content: '翻译全文'),
      ];
      final provider = _Provider(
        (_, _) => Stream.fromIterable([
          const ChatChunk(reasoningDelta: '确认术语'),
          ChatChunk(contentDelta: prose),
        ]),
      );
      final chunks =
          await DeepSeekReasoningGuard(
                delegate: provider,
                maxReasoningChars: 10,
              )
              .streamChat(config: _config, messages: messages, thinking: true)
              .toList();
      expect(provider.requests, hasLength(1));
      final prompt = provider.requests.single.messages.first.content;
      expect(prompt, startsWith('保留术语表和用户文风。'));
      expect(prompt, contains('不要在思考中生成整篇译文'));
      expect(prompt, contains('不得以缩短、遗漏正文为代价'));
      expect(messages.first.content, '保留术语表和用户文风。');
      expect(chunks.map((c) => c.contentDelta ?? '').join(), prose);
    },
  );

  test('task wrap-up forbids a nested reasoning recovery request', () async {
    final provider = _Provider(
      (_, _) => Stream.value(const ChatChunk(reasoningDelta: '只有思考')),
    );
    await expectLater(
      DeepSeekReasoningGuard(delegate: provider)
          .streamChat(
            config: _config.copyWith(allowReasoningRetry: false),
            messages: _messages,
            thinking: false,
          )
          .toList(),
      throwsStateError,
    );
    expect(provider.requests, hasLength(1));
  });
  test(
    'reasoning limit cancels only its attempt and recovers once without thinking',
    () async {
      final parent = CancelToken();
      final original = [
        ..._messages,
        const LlmRequestMessage(
          role: MessageRole.assistant,
          content: '',
          toolCalls: [ToolCall(index: 0, id: 'call-1', name: 'web_search')],
        ),
        const LlmRequestMessage(
          role: MessageRole.tool,
          content: '搜索得到的资料',
          toolCallId: 'call-1',
        ),
      ];
      final provider = _Provider(
        (request, count) => Stream.fromIterable(
          count == 1
              ? [const ChatChunk(reasoningDelta: '持续思考但没有给用户答案')]
              : [const ChatChunk(contentDelta: '这是答复', finishReason: 'stop')],
        ),
      );
      final chunks =
          await DeepSeekReasoningGuard(delegate: provider, maxReasoningChars: 5)
              .streamChat(
                config: _config,
                messages: original,
                thinking: true,
                cancelToken: parent,
              )
              .toList();
      expect(provider.requests, hasLength(2));
      expect(provider.requests.first.cancelToken!.isCancelled, isTrue);
      expect(parent.isCancelled, isFalse);
      expect(provider.requests.last.thinking, isFalse);
      expect(provider.requests.last.messages.last, same(original.last));
      expect(chunks.map((c) => c.contentDelta ?? '').join(), '这是答复');
      expect(
        chunks.any((c) => c.reasoningDelta?.contains('系统提示') ?? false),
        isTrue,
      );
    },
  );

  test(
    'continuous reasoning is bounded by elapsed time, not idle time',
    () async {
      var cancelled = false;
      final provider = _Provider((request, count) {
        if (count == 2) {
          return Stream.value(const ChatChunk(contentDelta: '及时答复'));
        }
        final stream = StreamController<ChatChunk>();
        final timer = Timer.periodic(
          const Duration(milliseconds: 2),
          (_) => stream.add(const ChatChunk(reasoningDelta: '想')),
        );
        stream.onCancel = () {
          timer.cancel();
          cancelled = true;
        };
        return stream.stream;
      });
      final chunks =
          await DeepSeekReasoningGuard(
                delegate: provider,
                reasoningTimeout: const Duration(milliseconds: 20),
              )
              .streamChat(config: _config, messages: _messages, thinking: true)
              .toList();
      expect(cancelled, isTrue);
      expect(provider.requests, hasLength(2));
      expect(chunks.last.contentDelta, '及时答复');
    },
  );

  test(
    'reasoning-only normal completion recovers instead of publishing raw reasoning',
    () async {
      final provider = _Provider(
        (_, count) => Stream.fromIterable(
          count == 1
              ? [
                  const ChatChunk(
                    reasoningDelta: '只是在反复规划',
                    finishReason: 'stop',
                  ),
                ]
              : [const ChatChunk(contentDelta: '正文答复')],
        ),
      );
      final chunks = await DeepSeekReasoningGuard(
        delegate: provider,
      ).streamChat(config: _config, messages: _messages).toList();
      expect(provider.requests, hasLength(2));
      expect(chunks.map((c) => c.contentDelta ?? '').join(), '正文答复');
    },
  );

  test('misbehaving recovery stops after one retry', () async {
    final provider = _Provider(
      (_, _) => Stream.value(const ChatChunk(reasoningDelta: '仍在思考')),
    );
    await expectLater(
      DeepSeekReasoningGuard(
        delegate: provider,
      ).streamChat(config: _config, messages: _messages).toList(),
      throwsStateError,
    );
    expect(provider.requests, hasLength(2));
  });

  test(
    'partial answer or tool call disables the reasoning-only watchdog',
    () async {
      for (final output in [
        const ChatChunk(contentDelta: '答案'),
        const ChatChunk(
          toolCalls: [ToolCall(index: 0, id: 'c', name: 'generate_image')],
        ),
      ]) {
        final provider = _Provider(
          (_, _) => Stream.fromIterable([
            output,
            const ChatChunk(reasoningDelta: '后续内容不受正文前思考上限限制'),
          ]),
        );
        await DeepSeekReasoningGuard(
          delegate: provider,
          maxReasoningChars: 1,
        ).streamChat(config: _config, messages: _messages).drain<void>();
        expect(provider.requests, hasLength(1));
      }
    },
  );

  test('hosted search time does not consume the thinking deadline', () async {
    final activity = SearchActivity(
      id: 's',
      kind: SearchActivityKind.search,
      query: '查资料',
    );
    final provider = _Provider((_, _) async* {
      yield const ChatChunk(reasoningDelta: '需要搜索');
      yield ChatChunk(serverSearchActivity: activity);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      yield ChatChunk(
        serverSearchActivity: activity.copyWith(
          status: SearchActivityStatus.done,
        ),
      );
      yield const ChatChunk(contentDelta: '根据搜索结果答复');
    });
    await DeepSeekReasoningGuard(
      delegate: provider,
      reasoningTimeout: const Duration(milliseconds: 30),
    ).streamChat(config: _config, messages: _messages).drain<void>();
    expect(provider.requests, hasLength(1));
  });

  test(
    'user stop cancels a live request without triggering recovery',
    () async {
      final parent = CancelToken();
      final provider = _Provider(
        (_, _) => StreamController<ChatChunk>().stream,
      );
      final result = DeepSeekReasoningGuard(delegate: provider)
          .streamChat(config: _config, messages: _messages, cancelToken: parent)
          .toList();
      await Future<void>.delayed(Duration.zero);
      parent.cancel('user stop');
      await result;
      expect(provider.requests, hasLength(1));
      expect(provider.requests.single.cancelToken!.isCancelled, isTrue);
    },
  );

  test('other providers and their messages are unchanged', () async {
    final provider = _Provider(
      (_, _) => Stream.value(const ChatChunk(reasoningDelta: '其他模型的思考')),
    );
    final config = _config.copyWith(
      baseUrl: 'https://example.com',
      model: 'custom-model',
    );
    await DeepSeekReasoningGuard(
      delegate: provider,
      maxReasoningChars: 1,
    ).streamChat(config: config, messages: _messages).drain<void>();
    expect(provider.requests.single.messages, same(_messages));
  });
}
