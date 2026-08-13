import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/long_task_gateway_client.dart';
import 'package:expert_chat/features/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const connection = GatewayConnection(
    config: GatewayConfig(
      enabled: true,
      baseUrl: 'https://gateway.example.com',
      taskModel: 'document-model',
    ),
    apiToken: 'gateway-token',
  );

  test('uploads a file and creates a durable Gateway task', () async {
    final adapter = _GatewayAdapter();
    final client = LongTaskGatewayClient(
      dio: Dio()..httpClientAdapter = adapter,
    );
    final attachment = Attachment(
      name: 'notes.txt',
      mimeType: 'text/plain',
      sizeBytes: 5,
      text: 'hello',
      imageBase64: base64Encode(utf8.encode('hello')),
    );

    final fileId = await client.uploadFile(
      connection: connection,
      attachment: attachment,
      cancelToken: CancelToken(),
    );
    final created = await client.create(
      connection: connection,
      messages: const [
        LongTaskInputMessage(role: MessageRole.user, text: '深入分析'),
      ],
      fileIds: [fileId],
      cancelToken: CancelToken(),
      clientRequestId: 'message-123',
      instructions: '只依据文件',
    );

    expect(fileId, 'file_123');
    expect(created.id, 'task_123');
    expect(created.status, 'queued');
    expect(adapter.paths, ['/v1/files', '/v1/tasks']);
    expect(adapter.uploadSendTimeout, const Duration(seconds: 120));
    expect(adapter.createBody?['file_ids'], ['file_123']);
    expect(adapter.createBody?['prompt'], '深入分析');
    expect(adapter.createBody?['model'], 'document-model');
    expect(adapter.createBody?['client_request_id'], 'message-123');
  });

  test('large uploads receive a size-aware timeout budget', () async {
    final adapter = _GatewayAdapter();
    final client = LongTaskGatewayClient(
      dio: Dio()..httpClientAdapter = adapter,
    );
    final bytes = Uint8List(3849013);
    final attachment = Attachment(
      name: 'paper.pdf',
      mimeType: 'application/pdf',
      sizeBytes: bytes.length,
      imageBase64: base64Encode(bytes),
    );
    const slowConnection = GatewayConnection(
      config: GatewayConfig(
        enabled: true,
        baseUrl: 'https://gateway.example.com',
        requestTimeoutSeconds: 210,
      ),
      apiToken: 'gateway-token',
    );

    await client.uploadFile(
      connection: slowConnection,
      attachment: attachment,
      cancelToken: CancelToken(),
    );

    // 3,849,013 bytes at the conservative 8 KiB/s floor, plus 60 seconds.
    expect(adapter.uploadSendTimeout, const Duration(seconds: 530));
    expect(adapter.uploadReceiveTimeout, const Duration(seconds: 210));
  });

  test('dedicated upload URL is used only for file transfer', () async {
    final adapter = _GatewayAdapter();
    final client = LongTaskGatewayClient(
      dio: Dio()..httpClientAdapter = adapter,
    );
    const splitConnection = GatewayConnection(
      config: GatewayConfig(
        enabled: true,
        baseUrl: 'https://gateway.example.com',
        uploadBaseUrl: 'https://upload.example.com/',
      ),
      apiToken: 'gateway-token',
    );
    final attachment = Attachment(
      name: 'notes.txt',
      mimeType: 'text/plain',
      sizeBytes: 5,
      imageBase64: base64Encode(utf8.encode('hello')),
    );

    final fileId = await client.uploadFile(
      connection: splitConnection,
      attachment: attachment,
      cancelToken: CancelToken(),
    );
    await client.create(
      connection: splitConnection,
      messages: const [
        LongTaskInputMessage(role: MessageRole.user, text: 'analyze'),
      ],
      fileIds: [fileId],
      cancelToken: CancelToken(),
      clientRequestId: 'split-route',
    );

    expect(adapter.uris[0].host, 'upload.example.com');
    expect(adapter.uris[1].host, 'gateway.example.com');
  });

  test('unreachable dedicated upload URL falls back to main Gateway', () async {
    final adapter = _GatewayAdapter(failDedicatedUploadConnection: true);
    final client = LongTaskGatewayClient(
      dio: Dio()..httpClientAdapter = adapter,
    );
    const splitConnection = GatewayConnection(
      config: GatewayConfig(
        enabled: true,
        baseUrl: 'https://gateway.example.com',
        uploadBaseUrl: 'https://upload.example.com',
      ),
      apiToken: 'gateway-token',
    );
    final attachment = Attachment(
      name: 'notes.txt',
      mimeType: 'text/plain',
      sizeBytes: 5,
      imageBase64: base64Encode(utf8.encode('hello')),
    );

    final fileId = await client.uploadFile(
      connection: splitConnection,
      attachment: attachment,
      cancelToken: CancelToken(),
    );

    expect(fileId, 'file_123');
    expect(adapter.uris.map((uri) => uri.host), [
      'upload.example.com',
      'gateway.example.com',
    ]);
  });

  test('dedicated upload send timeout falls back to main Gateway', () async {
    final adapter = _GatewayAdapter(failDedicatedUploadSend: true);
    final client = LongTaskGatewayClient(
      dio: Dio()..httpClientAdapter = adapter,
    );
    const splitConnection = GatewayConnection(
      config: GatewayConfig(
        enabled: true,
        baseUrl: 'https://gateway.example.com',
        uploadBaseUrl: 'https://upload.example.com',
      ),
      apiToken: 'gateway-token',
    );
    final attachment = Attachment(
      name: 'notes.txt',
      mimeType: 'text/plain',
      sizeBytes: 5,
      imageBase64: base64Encode(utf8.encode('hello')),
    );

    final fileId = await client.uploadFile(
      connection: splitConnection,
      attachment: attachment,
      cancelToken: CancelToken(),
    );

    expect(fileId, 'file_123');
    expect(adapter.uris.map((uri) => uri.host), [
      'upload.example.com',
      'gateway.example.com',
    ]);
  });

  test('retrieves completed output text and supports cancellation', () async {
    final adapter = _GatewayAdapter();
    final client = LongTaskGatewayClient(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final snapshot = await client.retrieve(
      connection: connection,
      taskId: 'task_123',
    );
    expect(snapshot.isCompleted, isTrue);
    expect(snapshot.outputText, '最终分析结果');

    await client.cancel(connection: connection, taskId: 'task_123');
    await client.deleteFile(connection: connection, fileId: 'file_123');
    expect(adapter.paths, [
      '/v1/tasks/task_123',
      '/v1/tasks/task_123/cancel',
      '/v1/files/file_123',
    ]);
  });

  test('long task metadata survives JSON round trip', () {
    final task = LongTaskState(
      status: LongTaskStatus.running,
      providerProfileId: 'profile-1',
      providerName: '文件长任务 Gateway',
      baseUrl: connection.config.baseUrl,
      uploadBaseUrl: 'https://upload.example.com',
      model: connection.config.taskModel,
      taskId: 'task_123',
      remoteFileIds: const ['file_123'],
      progress: 0.6,
      lastEventId: 17,
      detail: '服务端正在处理',
    );
    final restored = LongTaskState.fromJson(task.toJson());
    expect(restored.status, LongTaskStatus.running);
    expect(restored.taskId, 'task_123');
    expect(restored.uploadBaseUrl, 'https://upload.example.com');
    expect(restored.remoteFileIds, ['file_123']);
    expect(restored.progress, 0.6);
    expect(restored.lastEventId, 17);
    expect(restored.isActive, isTrue);
  });

  testWidgets('assistant bubble renders long task progress and cancel', (
    tester,
  ) async {
    var cancelled = false;
    final task = LongTaskState(
      status: LongTaskStatus.running,
      providerProfileId: 'profile-1',
      providerName: '文件长任务 Gateway',
      baseUrl: connection.config.baseUrl,
      model: connection.config.taskModel,
      taskId: 'task_123',
      progress: 0.42,
      detail: '服务端正在处理，可离开此会话',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              role: MessageRole.assistant,
              content: '',
              longTask: task,
            ),
            isStreaming: false,
            onCancelLongTask: () => cancelled = true,
          ),
        ),
      ),
    );

    expect(find.text('正在后台处理文档'), findsOneWidget);
    expect(find.textContaining('可以离开当前会话'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('取消'));
    expect(cancelled, isTrue);
  });
}

class _GatewayAdapter implements HttpClientAdapter {
  _GatewayAdapter({
    this.failDedicatedUploadConnection = false,
    this.failDedicatedUploadSend = false,
  });

  final bool failDedicatedUploadConnection;
  final bool failDedicatedUploadSend;
  final paths = <String>[];
  final uris = <Uri>[];
  Map<String, dynamic>? createBody;
  Duration? uploadSendTimeout;
  Duration? uploadReceiveTimeout;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    uris.add(options.uri);
    final path = options.uri.path;
    if (path == '/v1/files' && options.method == 'POST') {
      if (failDedicatedUploadConnection &&
          options.uri.host == 'upload.example.com') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'dedicated upload endpoint unavailable',
        );
      }
      if (failDedicatedUploadSend && options.uri.host == 'upload.example.com') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.sendTimeout,
          message: 'dedicated upload endpoint timed out while sending',
        );
      }
      expect(options.data, isA<FormData>());
      uploadSendTimeout = options.sendTimeout;
      uploadReceiveTimeout = options.receiveTimeout;
      return _json({'id': 'file_123', 'object': 'file'});
    }
    if (path == '/v1/tasks' && options.method == 'POST') {
      createBody = Map<String, dynamic>.from(options.data as Map);
      return _json({'id': 'task_123', 'status': 'queued', 'progress': 0});
    }
    if (path == '/v1/tasks/task_123' && options.method == 'GET') {
      return _json({
        'id': 'task_123',
        'status': 'completed',
        'output_text': '最终分析结果',
        'progress': 1,
        'last_event_id': 9,
      });
    }
    if (path.endsWith('/cancel') ||
        (path == '/v1/files/file_123' && options.method == 'DELETE')) {
      return _json({'id': 'ok'});
    }
    return _json({
      'error': {'message': 'unexpected $path'},
    }, status: 404);
  }

  ResponseBody _json(Map<String, dynamic> body, {int status = 200}) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );

  @override
  void close({bool force = false}) {}
}
