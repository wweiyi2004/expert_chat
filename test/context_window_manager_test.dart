import 'package:flutter_test/flutter_test.dart';

import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/context/context_window_manager.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';

void main() {
  const manager = ContextWindowManager();

  test('ContextPrefs validates persisted numeric bounds', () {
    final prefs = ContextPrefs.fromJson({
      'contextWindowTokens': 100,
      'reservedOutputTokens': 999999,
      'maxHistoryMessages': 999,
    });

    expect(prefs.contextWindowTokens, 4096);
    expect(prefs.reservedOutputTokens, 3072);
    // The settings Slider renders 4..64; persisted values must land inside.
    expect(prefs.maxHistoryMessages, 64);

    final low = ContextPrefs.fromJson({'maxHistoryMessages': 2});
    expect(low.maxHistoryMessages, 4);
  });

  test('disabled management preserves the request verbatim', () {
    const messages = [
      LlmRequestMessage(role: MessageRole.system, content: 'system'),
      LlmRequestMessage(role: MessageRole.user, content: 'hello'),
    ];

    final result = manager.manage(messages, const ContextPrefs(enabled: false));

    expect(result.messages, messages);
    expect(result.report.managed, isFalse);
  });

  test('drops oldest history while preserving system and latest user turn', () {
    final messages = <LlmRequestMessage>[
      const LlmRequestMessage(
        role: MessageRole.system,
        content: 'Always answer clearly.',
      ),
      for (var i = 0; i < 10; i++)
        LlmRequestMessage(
          role: i.isEven ? MessageRole.user : MessageRole.assistant,
          content: 'message-$i ${'x' * 120}',
        ),
      const LlmRequestMessage(
        role: MessageRole.user,
        content: 'LATEST QUESTION',
      ),
    ];

    final result = manager.manage(
      messages,
      const ContextPrefs(
        contextWindowTokens: 4096,
        reservedOutputTokens: 3072,
        maxHistoryMessages: 6,
      ),
    );

    expect(result.messages.first.role, MessageRole.system);
    expect(result.messages.last.content, contains('LATEST QUESTION'));
    expect(result.report.droppedMessages, greaterThan(0));
    expect(result.report.sentTokens, lessThanOrEqualTo(1024));
  });

  test('clips an oversized latest user message from the front', () {
    final longAttachment = '附件内容' * 2000;
    final result = manager.manage(
      [
        LlmRequestMessage(
          role: MessageRole.user,
          content: '$longAttachment\n真正的问题：结论是什么？',
        ),
      ],
      const ContextPrefs(contextWindowTokens: 4096, reservedOutputTokens: 3072),
    );

    expect(result.report.truncated, isTrue);
    expect(result.messages.single.content, startsWith('[较早内容已因上下文限制裁剪]'));
    expect(result.messages.single.content, endsWith('真正的问题：结论是什么？'));
  });

  test('retains current image parts when text must be clipped', () {
    final result = manager.manage(
      [
        LlmRequestMessage(
          role: MessageRole.user,
          content: 'x' * 10000,
          imageDataUrls: const ['data:image/png;base64,AAAA'],
        ),
      ],
      const ContextPrefs(contextWindowTokens: 4096, reservedOutputTokens: 3072),
    );

    expect(result.messages.single.imageDataUrls, hasLength(1));
    expect(
      result.report.sentTokens,
      greaterThan(result.report.inputBudgetTokens),
    );
  });

  test('keeps assistant tool calls together with their tool responses', () {
    const call = ToolCall(
      index: 0,
      id: 'call-1',
      name: 'web_search',
      argumentsJson: '{"query":"test"}',
    );
    final result = manager.manage(
      [
        const LlmRequestMessage(
          role: MessageRole.user,
          content: 'an old question',
        ),
        const LlmRequestMessage(
          role: MessageRole.assistant,
          content: '',
          toolCalls: [call],
        ),
        LlmRequestMessage(
          role: MessageRole.tool,
          content: '搜索结果' * 2000,
          toolCallId: 'call-1',
        ),
      ],
      const ContextPrefs(contextWindowTokens: 4096, reservedOutputTokens: 3072),
    );

    expect(result.messages, hasLength(2));
    expect(result.messages.first.toolCalls.single.id, 'call-1');
    expect(result.messages.last.role, MessageRole.tool);
    expect(result.messages.last.toolCallId, 'call-1');
    expect(result.report.truncated, isTrue);
  });

  test('keeps the current user question when tool units fill the cap', () {
    const call1 = ToolCall(
      index: 0,
      id: 'call-1',
      name: 'web_search',
      argumentsJson: '{"query":"first"}',
    );
    const call2 = ToolCall(
      index: 0,
      id: 'call-2',
      name: 'web_search',
      argumentsJson: '{"query":"second"}',
    );

    // Tool follow-up turn: the newest units are tool-call protocol, so a
    // small history cap must not squeeze out the question being answered.
    final result = manager.manage(
      const [
        LlmRequestMessage(role: MessageRole.user, content: 'CURRENT QUESTION'),
        LlmRequestMessage(
          role: MessageRole.assistant,
          content: '',
          toolCalls: [call1],
        ),
        LlmRequestMessage(
          role: MessageRole.tool,
          content: 'result-1',
          toolCallId: 'call-1',
        ),
        LlmRequestMessage(
          role: MessageRole.assistant,
          content: '',
          toolCalls: [call2],
        ),
        LlmRequestMessage(
          role: MessageRole.tool,
          content: 'result-2',
          toolCallId: 'call-2',
        ),
      ],
      const ContextPrefs(maxHistoryMessages: 4),
    );

    expect(result.messages.map((m) => m.content), contains('CURRENT QUESTION'));
    expect(result.messages.last.toolCallId, 'call-2');
  });

  test('keeps a mid-conversation system message in place', () {
    // Search context is deliberately injected right before the newest user
    // message (chat_controller); management must not hoist it to the front.
    final result = manager.manage(
      const [
        LlmRequestMessage(role: MessageRole.system, content: 'persona'),
        LlmRequestMessage(role: MessageRole.user, content: 'older question'),
        LlmRequestMessage(role: MessageRole.assistant, content: 'older answer'),
        LlmRequestMessage(role: MessageRole.system, content: 'SEARCH CONTEXT'),
        LlmRequestMessage(role: MessageRole.user, content: 'current question'),
      ],
      const ContextPrefs(),
    );

    final contents = result.messages.map((m) => m.content).toList();
    expect(contents.first, 'persona');
    expect(contents.indexOf('SEARCH CONTEXT'), contents.length - 2);
    expect(contents.last, 'current question');
  });
}
