import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/request_transport_adaptation.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const config = LlmConfig(
    baseUrl: 'https://api.deepseek.com/v1',
    apiKey: 'old',
    model: 'deepseek-chat',
    profileId: 'accepted',
  );
  test(
    'same-wire DeepSeek key rotation preserves mandatory plain reasoning but drops account opaque state',
    () {
      const original = LlmRequestMessage(
        role: MessageRole.assistant,
        content: 'public',
        reasoningContent: 'provider continuation',
        toolCalls: [
          ToolCall(index: 0, id: 'call', name: 'read', argumentsJson: '{}'),
        ],
        responseOutputItems: [
          {'type': 'reasoning', 'encrypted_content': 'old-account'},
        ],
        imageFileIds: ['old-upload'],
      );
      final adapted = adaptHistoryForTransport(
        [original],
        previous: config,
        next: config.copyWith(apiKey: 'new'),
      );
      expect(adapted.single.reasoningContent, 'provider continuation');
      expect(adapted.single.toolCalls.single.id, 'call');
      expect(adapted.single.responseOutputItems, isEmpty);
      expect(adapted.single.imageFileIds, isEmpty);
      expect(original.responseOutputItems, isNotEmpty);
      expect(original.imageFileIds, ['old-upload']);
    },
  );
  test(
    'vision to text sends text fallback and preserves original pixels for UI recovery',
    () {
      const previous = LlmConfig(
        baseUrl: 'https://vision.invalid/v1',
        apiKey: 'x',
        model: 'gpt-4o',
      );
      const image = LlmRequestMessage(
        role: MessageRole.user,
        content: 'observed',
        imageDataUrls: ['data:image/png;base64,AAAA'],
        imageFileIds: ['file-id'],
        isToolImageObservation: true,
        toolImageCallId: 'capture',
      );
      final adapted = adaptHistoryForTransport(
        [image],
        previous: previous,
        next: config,
      );
      expect(adapted.single.hasImageParts, isFalse);
      expect(adapted.single.content, contains('像素未发送'));
      expect(adapted.single.toolImageCallId, 'capture');
      expect(image.imageDataUrls, isNotEmpty);
    },
  );
  test(
    'OAuth token refresh and text-only timeout changes do not discard valid same-account continuation',
    () {
      const oauth = LlmConfig(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'token1',
        model: 'gpt-4o',
        authMode: 'chatgpt',
        apiFormat: LlmApiFormat.openAiResponses,
        profileId: 'account',
      );
      const state = LlmRequestMessage(
        role: MessageRole.assistant,
        content: 'public',
        responseOutputItems: [
          {'type': 'reasoning', 'id': 'same-account'},
        ],
      );
      expect(
        adaptHistoryForTransport(
          [state],
          previous: oauth,
          next: oauth.copyWith(apiKey: 'token2'),
        ).single.responseOutputItems,
        isNotEmpty,
      );
      expect(
        adaptHistoryForTransport(
          [state],
          previous: config,
          next: config.copyWith(
            responseHeaderTimeout: const Duration(seconds: 300),
          ),
        ).single.responseOutputItems,
        isNotEmpty,
      );
    },
  );
}
