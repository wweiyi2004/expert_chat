import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_files_client.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/domain/llm/routing_llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseDataUrl extracts mime, bytes and filename', () {
    const raw = 'data:image/png;base64,AAAA';
    final parsed = OpenAiCompatibleFilesClient.parseDataUrl(raw);
    expect(parsed?.mimeType, 'image/png');
    expect(parsed?.filename, 'image.png');
    expect(parsed?.bytes, base64Decode('AAAA'));
  });

  test('uploadBytes posts multipart /files and caches the id', () async {
    final adapter = _FilesAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = OpenAiCompatibleFilesClient(dio: dio);
    const config = LlmConfig(
      baseUrl: 'https://api.deepseek.com',
      apiKey: 'k',
      model: 'deepseek-v4-flash-vision-exp',
    );
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    final first = await client.uploadBytes(
      config: config,
      bytes: bytes,
      filename: 'image.png',
      mimeType: 'image/png',
    );
    final second = await client.uploadBytes(
      config: config,
      bytes: bytes,
      filename: 'image.png',
      mimeType: 'image/png',
    );

    expect(first, 'file-api-1');
    expect(second, 'file-api-1');
    expect(adapter.uploadCount, 1);
    expect(adapter.path, endsWith('/files'));
  });

  test('attachFileIds rewrites DeepSeek vision data URLs to file_id', () async {
    final adapter = _FilesAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = OpenAiCompatibleFilesClient(dio: dio);
    const config = LlmConfig(
      baseUrl: 'https://api.deepseek.com',
      apiKey: 'k',
      model: 'deepseek-v4-flash-vision-exp',
    );

    final resolved = await client.attachFileIds(
      config: config,
      messages: const [
        LlmRequestMessage(
          role: MessageRole.user,
          content: '看图',
          imageDataUrls: ['data:image/png;base64,AAAA'],
        ),
      ],
    );

    expect(resolved.single.imageFileIds, ['file-api-1']);
    expect(resolved.single.imageDataUrls, isEmpty);
  });

  test(
    'attachFileIds leaves public URLs and non-DeepSeek hosts alone',
    () async {
      final adapter = _FilesAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final client = OpenAiCompatibleFilesClient(dio: dio);

      final public = await client.attachFileIds(
        config: const LlmConfig(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'k',
          model: 'deepseek-v4-flash-vision-exp',
        ),
        messages: const [
          LlmRequestMessage(
            role: MessageRole.user,
            content: '看图',
            imageDataUrls: ['https://example.com/a.png'],
          ),
        ],
      );
      expect(public.single.imageDataUrls, ['https://example.com/a.png']);
      expect(public.single.imageFileIds, isEmpty);
      expect(adapter.uploadCount, 0);

      final otherHost = await client.attachFileIds(
        config: const LlmConfig(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'k',
          model: 'gpt-4o',
        ),
        messages: const [
          LlmRequestMessage(
            role: MessageRole.user,
            content: '看图',
            imageDataUrls: ['data:image/png;base64,AAAA'],
          ),
        ],
      );
      expect(otherHost.single.imageDataUrls, ['data:image/png;base64,AAAA']);
      expect(adapter.uploadCount, 0);
    },
  );

  test(
    'RoutingLlmProvider uploads DeepSeek images before chat completions',
    () async {
      final filesAdapter = _FilesAdapter();
      final chatAdapter = _ChatAdapter();
      final files = OpenAiCompatibleFilesClient(
        dio: Dio()..httpClientAdapter = filesAdapter,
      );
      final chat = OpenAiCompatibleProvider(
        dio: Dio()..httpClientAdapter = chatAdapter,
      );
      final router = RoutingLlmProvider(chatCompletions: chat, files: files);

      await router
          .streamChat(
            config: const LlmConfig(
              baseUrl: 'https://api.deepseek.com',
              apiKey: 'k',
              model: 'deepseek-v4-flash-vision-exp',
            ),
            messages: const [
              LlmRequestMessage(
                role: MessageRole.user,
                content: '看图',
                imageDataUrls: ['data:image/png;base64,AAAA'],
              ),
            ],
          )
          .toList();

      expect(filesAdapter.uploadCount, 1);
      final content =
          (chatAdapter.body['messages'] as List).single['content'] as List;
      expect(content.last, {'type': 'file', 'file_id': 'file-api-1'});
    },
  );
}

class _FilesAdapter implements HttpClientAdapter {
  var uploadCount = 0;
  String path = '';

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uploadCount += 1;
    path = options.uri.path;
    return ResponseBody.fromString(
      jsonEncode({
        'id': 'file-api-1',
        'object': 'file',
        'filename': 'image.png',
        'purpose': 'user_data',
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _ChatAdapter implements HttpClientAdapter {
  Map<String, dynamic> body = const {};

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.data is String) {
      body = jsonDecode(options.data as String) as Map<String, dynamic>;
    }
    return ResponseBody.fromString(
      'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }
}
