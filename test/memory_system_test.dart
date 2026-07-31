import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/memory_file_store_io.dart';
import 'package:expert_chat/data/memory_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/memory/memory_candidate_service.dart';
import 'package:expert_chat/domain/memory/memory_codec.dart';
import 'package:expert_chat/domain/memory/memory_entry.dart';
import 'package:expert_chat/domain/memory/memory_safety.dart';
import 'package:expert_chat/domain/memory/memory_transfer.dart';
import 'package:expert_chat/features/memory/memory_candidate_review_sheet.dart';
import 'package:expert_chat/features/memory/memory_import_review_sheet.dart';
import 'package:expert_chat/features/memory/memory_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/memory_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements MemoryStore {
  String? markdown;

  /// Simulates a read landing in the "main file moved aside" window of a
  /// queued write, where the store reports the file as absent.
  bool simulateMissingFile = false;

  @override
  Future<String> locationLabel() async => 'memory-test.md';

  @override
  Future<String?> read() async =>
      simulateMissingFile ? null : markdown;

  @override
  Future<void> write(String markdown) async => this.markdown = markdown;
}

class _ConversationStore implements ConversationRepository {
  final conversations = <Conversation>[];

  @override
  Future<void> deleteConversation(String id) async {
    conversations.removeWhere((conversation) => conversation.id == id);
  }

  @override
  Future<List<Conversation>> loadAll() async => conversations;

  @override
  Future<void> saveAll(List<Conversation> conversations) async {
    this.conversations
      ..clear()
      ..addAll(conversations);
  }

  @override
  Future<void> saveConversation(Conversation conversation) async {
    final index = conversations.indexWhere(
      (item) => item.id == conversation.id,
    );
    if (index < 0) {
      conversations.add(conversation);
    } else {
      conversations[index] = conversation;
    }
  }
}

class _MemorySettings extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: '测试模型',
      baseUrl: 'https://example.com/v1',
      chatModel: 'test-model',
      reasonerModel: 'test-model',
      models: const ['test-model'],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
      memoryEnabled: true,
    );
  }
}

class _RecordingLlm implements LlmProvider {
  List<LlmRequestMessage> lastMessages = const [];

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  }) async* {
    lastMessages = List.unmodifiable(messages);
    yield const ChatChunk(contentDelta: '完成');
  }
}

class _CandidateLlm implements LlmProvider {
  _CandidateLlm(this.parts);

  final List<String> parts;
  List<LlmRequestMessage> lastMessages = const [];
  bool? lastThinking;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  }) async* {
    lastMessages = List.unmodifiable(messages);
    lastThinking = thinking;
    for (final part in parts) {
      yield ChatChunk(contentDelta: part);
    }
  }
}

void main() {
  test('Markdown memory document is readable and round-trips provenance', () {
    final now = DateTime.parse('2026-07-29T12:00:00Z');
    final document = MemoryDocument(
      revision: 4,
      updatedAt: now,
      entries: [
        MemoryEntry(
          id: 'memory-1',
          content: '默认使用中文回答。',
          sourceConversationId: 'conversation-1',
          sourceMessageId: 'message-1',
          sourceRole: 'user',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    const codec = MemoryMarkdownCodec();
    final markdown = codec.encode(document);
    final restored = codec.decode(markdown);

    expect(markdown, contains('# Expert Chat 长期记忆'));
    expect(markdown, contains('默认使用中文回答。'));
    expect(restored.revision, 4);
    expect(restored.entries.single.id, 'memory-1');
    expect(restored.entries.single.sourceMessageId, 'message-1');
    expect(restored.entries.single.pinned, isTrue);
  });

  test('sensitive credentials are rejected before file persistence', () {
    expect(
      () => MemorySafety.normalize('api_key = sk-1234567890abcdef'),
      throwsA(isA<MemoryValidationException>()),
    );
    expect(
      () => MemorySafety.normalize('-----BEGIN OPENSSH PRIVATE KEY----- abc'),
      throwsA(isA<MemoryValidationException>()),
    );
    expect(MemorySafety.normalize('项目数据优先保存在本机。'), '项目数据优先保存在本机。');
  });

  test(
    'repository deduplicates and recalls pinned plus relevant memories',
    () async {
      final store = _MemoryStore();
      final repository = MemoryRepository(store);
      final first = await repository.add(content: '回答默认使用中文。');
      final duplicate = await repository.add(content: '回答 默认 使用 中文。');
      await repository.add(
        content: 'Expert Chat 使用 Flutter 开发。',
        pinned: false,
      );
      await repository.add(content: '喜欢研究烘焙配方。', pinned: false);

      expect(first.created, isTrue);
      expect(duplicate.created, isFalse);

      final recall = await repository.recall('Flutter 项目应该如何实现？');
      expect(
        recall.entries.map((entry) => entry.content),
        containsAll(['回答默认使用中文。', 'Expert Chat 使用 Flutter 开发。']),
      );
      expect(
        recall.entries.map((entry) => entry.content),
        isNot(contains('喜欢研究烘焙配方。')),
      );
      expect(recall.toSystemPrompt(), contains('以当前消息为准'));
      expect(store.markdown, contains('scope: global'));
    },
  );

  test(
    'recall filters credentials manually pasted into the Markdown file',
    () async {
      final store = _MemoryStore();
      const codec = MemoryMarkdownCodec();
      store.markdown = codec.encode(
        MemoryDocument(
          revision: 1,
          entries: [
            MemoryEntry(content: 'password = never-send-this-secret'),
            MemoryEntry(content: '项目使用本地优先设计。'),
          ],
        ),
      );
      final recall = await MemoryRepository(store).recall('项目设计');

      expect(recall.entries, hasLength(1));
      expect(recall.entries.single.content, contains('本地优先'));
    },
  );

  group('文件存储崩溃恢复', () {
    late Directory tempDirectory;
    late String filePath;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp('memory_test_');
      filePath =
          '${tempDirectory.path}${Platform.pathSeparator}global.memory.md';
    });

    tearDown(() async {
      await tempDirectory.delete(recursive: true);
    });

    test('主文件缺失但 .bak 存在时,read 从 .bak 恢复内容', () async {
      final store = MemoryFileStore(null, filePath: filePath);
      await File('$filePath.bak').writeAsString('backup 内容');

      final markdown = await store.read();

      expect(markdown, 'backup 内容');
      // 无写入进行中时,恢复为“主文件就位”的正常状态。
      expect(await File(filePath).exists(), isTrue);
    });

    test('模拟崩溃窗口后,下一次写入不会丢失 .bak 中的数据', () async {
      final store = MemoryFileStore(null, filePath: filePath);
      // 崩溃窗口:主文件已移到 .bak,新内容仍在 .tmp,进程被杀。
      await File('$filePath.bak').writeAsString('已提交内容');
      await File('$filePath.tmp').writeAsString('未提交的新内容');

      expect(await store.read(), '已提交内容');
      await store.write('已提交内容 + 新条目');

      expect(await File(filePath).readAsString(), '已提交内容 + 新条目');
      // 主文件是完整副本,.bak 已清理。
      expect(await File('$filePath.bak').exists(), isFalse);
    });

    test('崩溃后重启的仓库保留全部记忆并追加新条目', () async {
      final store = MemoryFileStore(null, filePath: filePath);
      final first = MemoryRepository(store);
      await first.add(content: '项目使用 Flutter 开发。');

      // 模拟崩溃窗口:主文件已被移成 .bak,新内容仍在 .tmp,进程被杀。
      await File(filePath).rename('$filePath.bak');
      await File('$filePath.tmp').writeAsString('未提交内容');

      // 新进程:缓存为空,必须从 .bak 恢复全部记忆,而不是空文档。
      final restarted = MemoryRepository(store);
      final recovered = await restarted.load(refresh: true);
      expect(
        recovered.entries.map((entry) => entry.content),
        contains('项目使用 Flutter 开发。'),
      );

      // 追加新记忆后,磁盘上必须同时包含旧记忆与新记忆。
      await restarted.add(content: '用户偏好中文回答。');
      final markdown = await File(filePath).readAsString();
      expect(markdown, contains('项目使用 Flutter 开发。'));
      expect(markdown, contains('用户偏好中文回答。'));
    });
  });

  test('空读不会覆盖已有缓存,后续写入不会清空全部记忆', () async {
    final store = _MemoryStore();
    final repository = MemoryRepository(store);
    await repository.add(content: '项目使用 Flutter 开发。');

    // 模拟读落在“主文件已被移走”的窗口内:read 返回 null。
    store.simulateMissingFile = true;
    final refreshed = await repository.load(refresh: true);
    expect(
      refreshed.entries.map((entry) => entry.content),
      contains('项目使用 Flutter 开发。'),
    );

    // 后续写入基于缓存中的完整内容,不会把全部记忆清空。
    await repository.add(content: '用户偏好中文回答。');
    expect(store.markdown, contains('项目使用 Flutter 开发。'));
    expect(store.markdown, contains('用户偏好中文回答。'));
  });

  test('首次使用没有文件时仍返回空文档', () async {
    final repository = MemoryRepository(_MemoryStore());
    final document = await repository.load();
    expect(document.entries, isEmpty);
  });

  test('candidate parser rejects unsupported, unsafe and duplicate facts', () {
    final existing = [
      MemoryEntry(id: 'memory-flutter', content: '项目使用 Flutter 开发。'),
      MemoryEntry(id: 'memory-drink', content: '用户每天喝咖啡。'),
    ];
    final candidates = MemoryCandidateService.parse(
      '''
模型说明：
```json
{
  "candidates": [
    {
      "content": "回答时默认使用中文。",
      "category": "preference",
      "confidence": 0.94,
      "reason": "稳定的交流偏好",
      "sourceMessageIds": ["user-1"]
    },
    {
      "content": "助手猜测用户住在上海。",
      "category": "profile_fact",
      "confidence": 0.9,
      "reason": "没有用户证据",
      "sourceMessageIds": ["assistant-1"]
    },
    {
      "content": "项目使用 Flutter 开发。",
      "category": "project_fact",
      "confidence": 0.99,
      "reason": "已有内容",
      "sourceMessageIds": ["user-1"]
    },
    {
      "content": "api_key = sk-1234567890abcdef",
      "category": "other",
      "confidence": 0.99,
      "reason": "敏感内容",
      "sourceMessageIds": ["user-1"]
    },
    {
      "content": "也许以后学习木工。",
      "category": "ongoing_task",
      "confidence": 0.4,
      "reason": "置信度不足",
      "sourceMessageIds": ["user-1"]
    },
    {
      "content": "用户现在不喝咖啡了。",
      "category": "preference",
      "confidence": 0.96,
      "reason": "用户明确更新了饮品习惯",
      "sourceMessageIds": ["user-1"],
      "relation": "update",
      "relatedMemoryIds": ["memory-drink"]
    },
    {
      "content": "用户改为每天喝茶。",
      "category": "preference",
      "confidence": 0.9,
      "reason": "引用了不存在的旧记忆",
      "sourceMessageIds": ["user-1"],
      "relation": "conflict",
      "relatedMemoryIds": ["memory-missing"]
    }
  ]
}
```
''',
      validUserMessageIds: const {'user-1'},
      existingMemories: existing,
    );

    expect(candidates, hasLength(2));
    expect(candidates.first.content, '回答时默认使用中文。');
    expect(candidates.first.category, MemoryCandidateCategory.preference);
    expect(candidates.first.sourceMessageIds, ['user-1']);
    final update = candidates.last;
    expect(update.relation, MemoryCandidateRelation.update);
    expect(update.relatedMemories.single.id, 'memory-drink');
  });

  test(
    'candidate service is explicit, bounded and uses non-thinking JSON',
    () async {
      final llm = _CandidateLlm([
        '{"candidates":[{"content":"用户现在不喝咖啡了。",',
        '"category":"preference","confidence":0.92,',
        '"reason":"个人习惯已更新","sourceMessageIds":["user-2"],',
        '"relation":"update","relatedMemoryIds":["memory-drink"]}]}',
      ]);
      final service = MemoryCandidateService(llm);
      final candidates = await service.extract(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1',
          apiKey: 'sk-test',
          model: 'chat-model',
        ),
        messages: [
          ChatMessage(
            id: 'assistant-1',
            role: MessageRole.assistant,
            content: '你之前说过每天喝咖啡。',
          ),
          ChatMessage(
            id: 'user-2',
            role: MessageRole.user,
            content: '我现在已经不喝咖啡了。',
          ),
        ],
        existingMemories: [
          MemoryEntry(id: 'memory-drink', content: '用户每天喝咖啡。'),
        ],
      );

      expect(candidates.single.content, '用户现在不喝咖啡了。');
      expect(candidates.single.relation, MemoryCandidateRelation.update);
      expect(candidates.single.relatedMemories.single.id, 'memory-drink');
      expect(llm.lastThinking, isFalse);
      expect(llm.lastMessages, hasLength(2));
      expect(llm.lastMessages.first.role, MessageRole.system);
      expect(llm.lastMessages.last.content, contains('user | user-2'));
      expect(llm.lastMessages.last.content, contains('已有长期记忆'));
      expect(llm.lastMessages.last.content, contains('[memory-drink]'));
    },
  );

  test(
    'confirmed candidate batch adds, atomically replaces and skips duplicates',
    () async {
      final repository = MemoryRepository(_MemoryStore());
      await repository.add(content: '默认使用中文回答。');
      final oldDrink = await repository.add(content: '用户每天喝咖啡。');
      final container = ProviderContainer(
        overrides: [memoryRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      await container.read(memoryControllerProvider.future);

      final result = await container
          .read(memoryControllerProvider.notifier)
          .applyConfirmedCandidates([
            MemoryCandidateSelection(
              candidate: MemoryCandidate(
                content: '默认使用中文回答。',
                category: MemoryCandidateCategory.preference,
                confidence: 0.9,
                reason: '回答偏好',
                sourceMessageIds: const ['message-1'],
              ),
              mode: MemoryCandidateWriteMode.add,
            ),
            MemoryCandidateSelection(
              candidate: MemoryCandidate(
                content: '用户喜欢简洁直接的回答。',
                category: MemoryCandidateCategory.preference,
                confidence: 0.9,
                reason: '回答偏好',
                sourceMessageIds: const ['message-2'],
              ),
              mode: MemoryCandidateWriteMode.add,
            ),
            MemoryCandidateSelection(
              candidate: MemoryCandidate(
                content: '用户现在不喝咖啡了。',
                category: MemoryCandidateCategory.preference,
                confidence: 0.96,
                reason: '饮品习惯已更新',
                sourceMessageIds: const ['message-3'],
                relation: MemoryCandidateRelation.update,
                relatedMemories: [oldDrink.entry],
              ),
              mode: MemoryCandidateWriteMode.replace,
            ),
          ], sourceConversationId: 'conversation-1');
      final document = await repository.load();

      expect(result.added, 1);
      expect(result.replaced, 1);
      expect(result.skipped, 1);
      expect(document.entries, hasLength(3));
      expect(
        document.entries.map((entry) => entry.content),
        isNot(contains('用户每天喝咖啡。')),
      );
      final saved = document.entries.last;
      expect(saved.content, '用户现在不喝咖啡了。');
      expect(saved.sourceConversationId, 'conversation-1');
      expect(saved.sourceMessageId, 'message-3');
      expect(saved.sourceRole, 'user_candidate_replacement');
    },
  );

  test(
    'memory backup preview classifies new, duplicate, conflict and unsafe',
    () {
      final current = MemoryDocument(
        entries: [
          MemoryEntry(id: 'memory-language', content: '默认使用中文回答。'),
          MemoryEntry(id: 'memory-drink', content: '用户每天喝咖啡。'),
        ],
      );
      final backup = MemoryDocument(
        revision: 8,
        entries: [
          MemoryEntry(id: 'memory-new', content: '用户喜欢简洁直接的回答。'),
          MemoryEntry(id: 'memory-copy', content: '默认 使用 中文 回答。'),
          MemoryEntry(id: 'memory-drink', content: '用户现在不喝咖啡了。'),
          MemoryEntry(
            id: 'memory-secret',
            content: 'api_key = sk-1234567890abcdef',
          ),
          MemoryEntry(id: 'bad id', content: 'ID 格式异常。'),
        ],
      );
      const service = MemoryTransferService();
      final plan = service.previewImport(
        service.exportDocument(backup),
        current: current,
      );

      expect(plan.sourceEntryCount, 5);
      expect(plan.newCount, 1);
      expect(plan.duplicateCount, 1);
      expect(plan.conflictCount, 1);
      expect(plan.blockedCount, 2);
      final conflict = plan.items.singleWhere(
        (item) => item.status == MemoryImportStatus.conflict,
      );
      expect(conflict.existing!.content, '用户每天喝咖啡。');
      expect(conflict.imported.content, '用户现在不喝咖啡了。');
    },
  );

  test('memory backup rejects unrelated Markdown', () {
    expect(
      () => const MemoryTransferService().previewImport(
        '# 普通 Markdown\n\n- 不是记忆备份',
        current: const MemoryDocument(),
      ),
      throwsA(isA<MemoryImportFormatException>()),
    );
  });

  test('reviewed backup merge adds and replaces in one revision', () async {
    final repository = MemoryRepository(_MemoryStore());
    await repository.add(
      content: '用户每天喝咖啡。',
      sourceConversationId: 'conversation-1',
      sourceMessageId: 'message-drink',
      sourceRole: 'user',
    );
    final before = await repository.load();
    final container = ProviderContainer(
      overrides: [memoryRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    await container.read(memoryControllerProvider.future);

    const service = MemoryTransferService();
    final backup = service.exportDocument(
      MemoryDocument(
        entries: [
          MemoryEntry(
            id: before.entries.single.id,
            content: '用户现在不喝咖啡了。',
            sourceConversationId: 'conversation-1',
            sourceMessageId: 'message-drink',
            sourceRole: 'user',
          ),
          MemoryEntry(id: 'memory-answer-style', content: '用户喜欢简洁直接的回答。'),
        ],
      ),
    );
    final controller = container.read(memoryControllerProvider.notifier);
    final plan = await controller.previewImport(backup);
    final result = await controller.applyImport([
      for (final item in plan.actionableItems)
        MemoryImportSelection(
          item: item,
          action: item.status == MemoryImportStatus.conflict
              ? MemoryImportAction.useImported
              : MemoryImportAction.add,
        ),
    ]);
    final after = await repository.load();

    expect(result.added, 1);
    expect(result.replaced, 1);
    expect(result.skipped, 0);
    expect(after.revision, before.revision + 1);
    expect(after.entries, hasLength(2));
    expect(
      after.entries.map((entry) => entry.content),
      containsAll(['用户现在不喝咖啡了。', '用户喜欢简洁直接的回答。']),
    );
    expect(
      after.entries.map((entry) => entry.content),
      isNot(contains('用户每天喝咖啡。')),
    );
  });

  test('enabled memory is injected into the model request', () async {
    final memoryRepository = MemoryRepository(_MemoryStore());
    await memoryRepository.add(content: '这个项目的数据必须优先保存在本机。');
    final llm = _RecordingLlm();
    final conversations = _ConversationStore();
    final container = ProviderContainer(
      overrides: [
        memoryRepositoryProvider.overrideWithValue(memoryRepository),
        llmProvider.overrideWithValue(llm),
        conversationRepositoryProvider.overrideWithValue(conversations),
        settingsControllerProvider.overrideWith(_MemorySettings.new),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await container.read(chatControllerProvider.future);
    expect(await controller.sendMessage('应该怎样保存数据？'), isTrue);

    final memoryMessage = llm.lastMessages.where(
      (message) =>
          message.role == MessageRole.system &&
          message.content.contains('用户保存的长期记忆'),
    );
    expect(memoryMessage, hasLength(1));
    expect(memoryMessage.single.content, contains('优先保存在本机'));
  });

  testWidgets('memory manager stays usable on a narrow phone screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = MemoryRepository(_MemoryStore());
    await repository.add(
      content: '这是一个包含足够长度、用于验证手机窄屏布局不会溢出的项目记忆。',
      sourceConversationId: 'conversation',
      sourceMessageId: 'message',
      sourceRole: 'user',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [memoryRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: MemoryPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('长期记忆'), findsOneWidget);
    expect(find.textContaining('手机窄屏布局'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('添加记忆'));
    await tester.pumpAndSettle();
    expect(find.text('添加长期记忆'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'candidate review on phone requires an explicit checkbox selection',
    (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final candidate = MemoryCandidate(
        id: 'candidate-1',
        content: '默认使用中文回答，并优先给出可直接执行的步骤。',
        category: MemoryCandidateCategory.preference,
        confidence: 0.95,
        reason: '稳定的回答偏好',
        sourceMessageIds: const ['user-1'],
      );
      List<MemoryCandidateSelection>? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () async {
                    result =
                        await showModalBottomSheet<
                          List<MemoryCandidateSelection>
                        >(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => MemoryCandidateReviewSheet(
                            candidates: [candidate],
                          ),
                        );
                  },
                  child: const Text('打开候选'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开候选'));
      await tester.pumpAndSettle();

      expect(find.text('确认候选记忆'), findsOneWidget);
      expect(find.text('保存 0 条'), findsOneWidget);
      final disabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '保存 0 条'),
      );
      expect(disabled.onPressed, isNull);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('默认使用中文回答，并优先给出可直接执行的步骤。'));
      await tester.pumpAndSettle();
      expect(find.text('保存 1 条'), findsOneWidget);

      await tester.tap(find.text('保存 1 条'));
      await tester.pumpAndSettle();
      expect(result, hasLength(1));
      expect(result!.single.candidate, candidate);
      expect(result!.single.mode, MemoryCandidateWriteMode.add);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('conflicting memory requires replace or keep-both choice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final candidate = MemoryCandidate(
      id: 'candidate-conflict',
      content: '用户现在不喝咖啡了。',
      category: MemoryCandidateCategory.preference,
      confidence: 0.96,
      reason: '饮品习惯已更新',
      sourceMessageIds: const ['user-2'],
      relation: MemoryCandidateRelation.update,
      relatedMemories: [MemoryEntry(id: 'memory-drink', content: '用户每天喝咖啡。')],
    );
    List<MemoryCandidateSelection>? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  result =
                      await showModalBottomSheet<
                        List<MemoryCandidateSelection>
                      >(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) =>
                            MemoryCandidateReviewSheet(candidates: [candidate]),
                      );
                },
                child: const Text('打开冲突候选'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开冲突候选'));
    await tester.pumpAndSettle();

    expect(find.text('可能更新'), findsOneWidget);
    expect(find.textContaining('用户每天喝咖啡。'), findsOneWidget);
    expect(find.text('替换旧记忆'), findsOneWidget);
    expect(find.text('两条都保留'), findsOneWidget);
    expect(find.text('暂不保存'), findsOneWidget);
    expect(find.text('保存 0 条'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('替换旧记忆'));
    await tester.pumpAndSettle();
    expect(find.text('保存 1 条'), findsOneWidget);
    await tester.tap(find.text('保存 1 条'));
    await tester.pumpAndSettle();

    expect(result, hasLength(1));
    expect(result!.single.mode, MemoryCandidateWriteMode.replace);
    expect(result!.single.candidate, candidate);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'memory import preview keeps conflicts unchanged by default on phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final current = MemoryEntry(id: 'memory-drink', content: '用户每天喝咖啡。');
      final newItem = MemoryImportItem(
        imported: MemoryEntry(id: 'memory-new', content: '用户喜欢简洁直接的回答。'),
        status: MemoryImportStatus.newEntry,
      );
      final conflictItem = MemoryImportItem(
        imported: MemoryEntry(id: 'memory-drink', content: '用户现在不喝咖啡了。'),
        existing: current,
        status: MemoryImportStatus.conflict,
      );
      final plan = MemoryImportPlan(
        items: [newItem, conflictItem],
        sourceEntryCount: 3,
        blockedCount: 1,
      );
      List<MemoryImportSelection>? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () async {
                    result =
                        await showModalBottomSheet<List<MemoryImportSelection>>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => MemoryImportReviewSheet(plan: plan),
                        );
                  },
                  child: const Text('打开导入预览'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开导入预览'));
      await tester.pumpAndSettle();

      expect(find.text('预览记忆备份'), findsOneWidget);
      expect(find.text('新增 1'), findsOneWidget);
      expect(find.text('不同版本 1'), findsOneWidget);
      expect(find.text('已拦截 1'), findsOneWidget);
      expect(find.text('合并 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        find.text('使用备份'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('使用备份'));
      await tester.pumpAndSettle();
      expect(find.text('合并 2 项'), findsOneWidget);
      await tester.tap(find.text('合并 2 项'));
      await tester.pumpAndSettle();

      expect(result, hasLength(2));
      expect(
        result!
            .singleWhere((selection) => selection.item == conflictItem)
            .action,
        MemoryImportAction.useImported,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
