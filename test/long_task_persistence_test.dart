import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/long_task_gateway_client.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FailingRepository extends DriftConversationRepository {
  _FailingRepository(super.db);

  bool failWrites = false;
  final attemptedRequestIds = <String>[];
  Completer<void>? preparingWriteStarted;
  Completer<void>? preparingWriteGate;

  @override
  Future<void> saveConversation(Conversation conversation) async {
    final task = conversation.messages.last.longTask!;
    if (task.status == LongTaskStatus.preparing) {
      attemptedRequestIds.add(task.clientRequestId!);
    }
    if (failWrites) throw StateError('synthetic storage failure');
    if (task.status == LongTaskStatus.preparing) {
      final started = preparingWriteStarted;
      if (started != null && !started.isCompleted) started.complete();
      await preparingWriteGate?.future;
    }
    await super.saveConversation(conversation);
  }
}

class _Settings extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    gateway: GatewayConfig(enabled: true, baseUrl: 'https://example.invalid'),
    gatewayToken: 'synthetic-token',
  );
}

class _Gateway extends LongTaskGatewayClient {
  _Gateway(this.repository);
  final _FailingRepository repository;
  final requestIds = <String>[];
  final finished = Completer<void>();
  int uploads = 0;
  LongTaskState? storedAtUpload;

  @override
  Future<String> uploadFile({
    required GatewayConnection connection,
    required Attachment attachment,
    required CancelToken cancelToken,
  }) async {
    uploads++;
    storedAtUpload = (await repository.loadConversation(
      'conversation',
    )).messages.last.longTask;
    return 'synthetic-file';
  }

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
    return const LongTaskSnapshot(
      id: 'new-task',
      status: 'completed',
      outputText: 'completed result',
    );
  }

  @override
  Future<void> deleteFile({
    required GatewayConnection connection,
    required String fileId,
  }) async {
    finished.complete();
  }
}

late SharedPreferences _testPreferences;
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _testPreferences = await SharedPreferences.getInstance();
  });
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'retry waits for durable attempt identity and remains retryable after save failure',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = _FailingRepository(db);
      final gateway = _Gateway(repository);
      await repository.saveConversation(
        Conversation(
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
              parentId: 'user',
              role: MessageRole.assistant,
              content: 'original partial result',
              longTask: LongTaskState(
                status: LongTaskStatus.failed,
                providerProfileId: '',
                providerName: 'gateway',
                baseUrl: 'https://example.invalid',
                model: 'test',
                taskId: 'old-task',
                clientRequestId: 'old-attempt',
                progress: 0.7,
                lastEventId: 8,
                error: 'original task error',
              ),
            ),
          ],
        ),
      );
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(_testPreferences),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(repository),
          longTaskGatewayClientProvider.overrideWithValue(gateway),
          settingsControllerProvider.overrideWith(_Settings.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);
      final controller = container.read(chatControllerProvider.notifier);
      final original = container
          .read(chatControllerProvider)
          .requireValue
          .current!
          .messages
          .last;
      repository.failWrites = true;

      await controller.retryLongTask('conversation', 'assistant');
      await pumpEventQueue();

      final afterFailure = container.read(chatControllerProvider).requireValue;
      expect(afterFailure.error, contains('synthetic storage failure'));
      expect(afterFailure.errorConvoId, 'conversation');
      expect(
        afterFailure.current!.messages.last.longTask!.toJson(),
        original.longTask!.toJson(),
      );
      expect(afterFailure.current!.messages.last.content, original.content);
      expect(afterFailure.current!.messages.last.longTask!.canRetry, isTrue);
      expect(
        (await repository.loadConversation(
          'conversation',
        )).messages.last.longTask!.clientRequestId,
        'old-attempt',
      );
      expect(gateway.uploads, 0);
      expect(gateway.requestIds, isEmpty);

      repository.failWrites = false;
      final started = repository.preparingWriteStarted = Completer<void>();
      final gate = repository.preparingWriteGate = Completer<void>();
      final retry = controller.retryLongTask('conversation', 'assistant');
      await started.future;
      final duplicateRetry = controller.retryLongTask(
        'conversation',
        'assistant',
      );
      await pumpEventQueue();
      try {
        expect(gateway.uploads, 0);
        expect(gateway.requestIds, isEmpty);
        expect(
          container
              .read(chatControllerProvider)
              .requireValue
              .current!
              .messages
              .last
              .longTask!
              .clientRequestId,
          'old-attempt',
        );
      } finally {
        gate.complete();
      }
      await Future.wait([retry, duplicateRetry]);
      await gateway.finished.future.timeout(const Duration(seconds: 5));

      expect(gateway.uploads, 1);
      expect(gateway.requestIds, hasLength(1));
      final requestId = gateway.requestIds.single;
      expect(requestId, isNot('old-attempt'));
      expect(repository.attemptedRequestIds, hasLength(2));
      expect(requestId, repository.attemptedRequestIds.last);
      expect(requestId, isNot(repository.attemptedRequestIds.first));
      expect(gateway.storedAtUpload!.clientRequestId, requestId);
      expect(gateway.storedAtUpload!.taskId, isNull);
      expect(gateway.storedAtUpload!.progress, 0);
      expect(gateway.storedAtUpload!.lastEventId, 0);
      final stored = (await repository.loadConversation(
        'conversation',
      )).messages.last;
      expect(stored.longTask!.status, LongTaskStatus.completed);
      expect(stored.longTask!.clientRequestId, requestId);
      expect(stored.longTask!.taskId, 'new-task');
      expect(stored.content, 'completed result');
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .current!
            .messages
            .last
            .longTask!
            .status,
        LongTaskStatus.completed,
      );
    },
  );
}
