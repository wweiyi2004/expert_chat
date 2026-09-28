import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/tool_image_context.dart';
import 'package:expert_chat/domain/context/context_window_manager.dart';
import 'package:expert_chat/domain/document/document_service_client.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.content, [this.structured = const {}]);
  final List<Map<String, dynamic>> content;
  final Map<String, dynamic> structured;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = options.data as Map;
    return ResponseBody.fromString(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {
          'content': content,
          'structuredContent': structured,
          'isError': false,
        },
      }),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'computer snapshot handles reach model text without raw image payloads',
    () async {
      final client = DocumentServiceClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            [
              {'type': 'text', 'text': '[0] Button Save'},
            ],
            {
              'snapshot_id': 's00000001',
              'pid': 123,
              'window_id': 456,
              'image_blob': 'private-payload',
              'elements': [
                {'element_index': 0, 'element_token': 's00000001:0'},
              ],
            },
          ),
      );
      final result = await client.callDiscoveredTool(
        connection: const GatewayConnection(
          config: GatewayConfig(enabled: true),
          apiToken: '',
          computerUse: true,
        ),
        name: 'get_window_state',
        arguments: {'pid': 123, 'window_id': 456},
      );
      expect(result.text, contains('s00000001:0'));
      expect(result.text, contains('snapshot_id'));
      expect(result.text, isNot(contains('private-payload')));
    },
  );
  Future<({String text, DocumentEditResult? file})> call(
    List<Map<String, dynamic>> content,
  ) => DocumentServiceClient(dio: Dio()..httpClientAdapter = _Adapter(content))
      .callDiscoveredTool(
        connection: const GatewayConnection(
          config: GatewayConfig(
            enabled: true,
            baseUrl: 'http://127.0.0.1:8791',
          ),
          apiToken: 'local-token',
        ),
        name: 'mobile_screenshot',
        arguments: const {},
      );

  test(
    'MCP inline screenshot becomes a usable image with its observation text',
    () async {
      final result = await call([
        {'type': 'text', 'text': 'Screen 1 x 1'},
        {'type': 'image', 'mimeType': 'image/png', 'data': _png},
      ]);
      expect(result.text, 'Screen 1 x 1');
      expect(result.file!.contentType, 'image/png');
      expect(result.file!.bytes, base64Decode(_png));
      final image = Attachment(
        name: result.file!.filename,
        mimeType: result.file!.contentType,
        sizeBytes: result.file!.bytes.length,
        imageBase64: base64Encode(result.file!.bytes),
        text: '',
      );
      final observation = ToolImageContext.observation(image);
      expect(observation.role, MessageRole.user);
      expect(
        observation.toOpenAiJson()['content'],
        contains(
          equals({
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,$_png'},
          }),
        ),
      );
      expect(
        observation.toOpenAiJson().containsKey('isToolImageObservation'),
        isFalse,
      );
    },
  );

  for (final bad in [
    {'type': 'image', 'mimeType': 'image/png', 'data': '!!!'},
    {'type': 'image', 'mimeType': 'image/jpeg', 'data': _png},
    {'type': 'image', 'mimeType': 'image/svg+xml', 'data': _png},
  ]) {
    test(
      'invalid image is reported instead of being silently dropped: ${bad['mimeType']}',
      () async {
        await expectLater(
          call([bad]),
          throwsA(isA<DocumentServiceException>()),
        );
      },
    );
  }

  test(
    'fresh screenshot removes only older tool images and retains tool protocol',
    () {
      const original = LlmRequestMessage(
        role: MessageRole.user,
        content: 'my image',
        imageDataUrls: ['user-image'],
      );
      const old = LlmRequestMessage(
        role: MessageRole.user,
        content: 'old screenshot',
        imageDataUrls: ['old-image'],
        isToolImageObservation: true,
      );
      const tool = LlmRequestMessage(
        role: MessageRole.tool,
        content: 'done',
        toolCallId: 'call1',
      );
      const fresh = LlmRequestMessage(
        role: MessageRole.user,
        content: 'new screenshot',
        imageDataUrls: ['new-image'],
        isToolImageObservation: true,
      );
      final history = <LlmRequestMessage>[original, old];
      ToolImageContext.append(history, [tool, fresh]);
      expect(history.first.imageDataUrls, ['user-image']);
      expect(history[1].hasImageParts, isFalse);
      expect(history[2].toolCallId, 'call1');
      expect(history.last.imageDataUrls, ['new-image']);
      final managed = const ContextWindowManager().manage(
        history,
        const ContextPrefs(),
      );
      expect(managed.messages.last.isToolImageObservation, isTrue);
    },
  );
}
