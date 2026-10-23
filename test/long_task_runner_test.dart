import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/long_task_configuration.dart';
import 'package:expert_chat/domain/chat/long_task_runner.dart';
import 'package:expert_chat/domain/llm/long_task_gateway_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway extends LongTaskGatewayClient {
  final requestIds = <String>[];
  bool interruptCreate = false;

  @override
  Future<String> uploadFile({
    required GatewayConnection connection,
    required Attachment attachment,
    required CancelToken cancelToken,
  }) async => 'synthetic-file';

  @override
  Future<LongTaskSnapshot> create({
    required GatewayConnection connection,
    required List<LongTaskInputMessage> messages,
    required List<String> fileIds,
    required CancelToken cancelToken,
    required String clientRequestId,
    String? instructions,
  }) async {
    requestIds.add(clientRequestId);
    if (interruptCreate) {
      throw DioException(
        requestOptions: RequestOptions(path: '/tasks'),
        type: DioExceptionType.cancel,
      );
    }
    return LongTaskSnapshot(
      id: 'task-$clientRequestId',
      status: 'failed',
      error: 'synthetic failure',
    );
  }

  @override
  Future<void> deleteFile({
    required GatewayConnection connection,
    required String fileId,
  }) async {}
}

void main() {
  test(
    'explicit retry creates a new persisted attempt; resume keeps that ID',
    () async {
      final client = _Gateway();
      var task = LongTaskState(
        status: LongTaskStatus.preparing,
        providerProfileId: '',
        providerName: 'gateway',
        baseUrl: 'https://example.invalid',
        model: 'test',
      );
      final conversation = Conversation(
        id: 'conversation',
        messages: [
          ChatMessage(
            id: 'user',
            role: MessageRole.user,
            content: 'summarize',
            attachments: [
              Attachment(
                name: 'file.txt',
                mimeType: 'text/plain',
                sizeBytes: 3,
                imageBase64: base64Encode(utf8.encode('abc')),
              ),
            ],
          ),
          ChatMessage(
            id: 'assistant',
            role: MessageRole.assistant,
            content: '',
            parentId: 'user',
          ),
        ],
      );
      final resets = <LongTaskState>[];
      LongTaskRunner runner() => LongTaskRunner(
        client: () => client,
        readSettings: () async => const LongTaskConfiguration(
          gateway: GatewayConfig(
            enabled: true,
            baseUrl: 'https://example.invalid',
          ),
          gatewayToken: 'synthetic',
          systemPrompt: '',
        ),
        conversations: () => [conversation],
        findTask: (_, _) => task,
        writeTask: (_, _, value, {content}) async {
          // Exercise the same JSON round trip used by persisted messages.
          task = LongTaskState.fromJson(value.toJson());
          if (value.status == LongTaskStatus.preparing) resets.add(task);
        },
        reportError: (error, {convoId}) => fail(error),
      );
      final first = runner();
      await first.run('conversation', 'assistant');
      expect(task.status, LongTaskStatus.failed);
      expect(client.requestIds, ['assistant']);

      task = task.copyWith(progress: 0.8, lastEventId: 12);
      client.interruptCreate = true;
      await first.retry('conversation', 'assistant');
      await pumpEventQueue();
      final attempt = client.requestIds.last;
      expect(attempt, isNot('assistant'));
      expect(resets.single.clientRequestId, attempt);
      expect(resets.single.progress, 0);
      expect(resets.single.lastEventId, 0);
      expect(task.isActive, isTrue);

      client.interruptCreate = false;
      await runner().run('conversation', 'assistant');
      expect(client.requestIds, ['assistant', attempt, attempt]);
      expect(task.status, LongTaskStatus.failed);
      await runner().retry('conversation', 'assistant');
      await pumpEventQueue();
      expect(client.requestIds.last, isNot(attempt));
    },
  );
}
