import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/tool_image_context.dart';
import 'package:expert_chat/domain/context/context_window_manager.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_files_client.dart';
import 'package:flutter_test/flutter_test.dart';

Attachment _image() =>
    Attachment(name: 'screen.png', mimeType: 'image/png', imageBase64: 'YWJj');

void main() {
  test(
    'observation associates its producing call without OpenAI protocol fields',
    () {
      final observation = ToolImageContext.observation(
        _image(),
        callId: 'source-call',
      );
      expect(observation.toolImageCallId, 'source-call');
      expect(observation.toolCallId, isNull);
      final json = observation.toOpenAiJson();
      expect(json['role'], 'user');
      expect(json.containsKey('toolImageCallId'), isFalse);
      expect(json.containsKey('isToolImageObservation'), isFalse);
      expect(json.containsKey('tool_call_id'), isFalse);
    },
  );

  test(
    'retiring screenshots keeps the association for their text placeholder',
    () {
      final history = [ToolImageContext.observation(_image(), callId: 'old')];
      ToolImageContext.append(history, [
        ToolImageContext.observation(_image(), callId: 'fresh'),
      ]);
      expect(history.first.hasImageParts, isFalse);
      expect(history.first.content, contains('旧截图已移出'));
      expect(history.first.toolImageCallId, 'old');
      expect(history.last.toolImageCallId, 'fresh');
      expect(history.last.hasImageParts, isTrue);
    },
  );

  test(
    'context trimming retains screenshot, source call and its result as one unit',
    () {
      final managed = const ContextWindowManager().manage(
        [
          const LlmRequestMessage(
            role: MessageRole.user,
            content: 'CURRENT TASK',
          ),
          const LlmRequestMessage(
            role: MessageRole.assistant,
            content: '',
            toolCalls: [
              ToolCall(
                index: 0,
                id: 'capture',
                name: 'screenshot',
                argumentsJson: '{}',
              ),
            ],
          ),
          LlmRequestMessage(
            role: MessageRole.tool,
            content: '工具输出' * 2000,
            toolCallId: 'capture',
          ),
          ToolImageContext.observation(_image(), callId: 'capture'),
        ],
        const ContextPrefs(
          contextWindowTokens: 4096,
          reservedOutputTokens: 2048,
          maxHistoryMessages: 1,
        ),
      );
      expect(managed.messages.map((m) => m.role), [
        MessageRole.user,
        MessageRole.assistant,
        MessageRole.tool,
        MessageRole.user,
      ]);
      expect(managed.messages.first.content, 'CURRENT TASK');
      expect(managed.messages[1].toolCalls.single.id, 'capture');
      expect(managed.messages[2].toolCallId, 'capture');
      expect(managed.messages.last.toolImageCallId, 'capture');
      expect(managed.messages.last.imageDataUrls, [
        'data:image/png;base64,YWJj',
      ]);
      expect(managed.report.truncated, isTrue);
      expect(managed.report.sentTokens, lessThanOrEqualTo(2048));
    },
  );

  test(
    'Files API message cloning preserves local screenshot association',
    () async {
      final client = OpenAiCompatibleFilesClient(
        dio: Dio()..httpClientAdapter = _FilesAdapter(),
      );
      final messages = await client.attachFileIds(
        config: const LlmConfig(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'test',
          model: 'deepseek-v4-flash-vision-exp',
        ),
        messages: [ToolImageContext.observation(_image(), callId: 'capture')],
      );
      expect(messages.single.imageFileIds, ['file-test']);
      expect(messages.single.toolImageCallId, 'capture');
      expect(messages.single.isToolImageObservation, isTrue);
      expect(
        messages.single.toOpenAiJson().containsKey('tool_call_id'),
        isFalse,
      );
    },
  );
}

class _FilesAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{"id":"file-test"}',
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
  @override
  void close({bool force = false}) {}
}
