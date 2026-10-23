import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/generation_repository.dart';
import 'package:expert_chat/data/library_file_store.dart';
import 'package:expert_chat/data/library_repository.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/memory_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/project_repository.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/media/image_edit_reference.dart';
import 'package:expert_chat/domain/media/image_prompt_safety.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';
import 'package:expert_chat/domain/memory/memory_codec.dart';
import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'widget_test.dart'
    show FakeImageGenSettings, FakeLlmProvider, FakeMediaProvider;

class _Memory implements MemoryStore {
  String value = '';
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String markdown) async {
    value = markdown;
  }

  @override
  Future<String> locationLabel() async => 'test';
}

class _Settings extends FakeImageGenSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    memoryEnabled: true,
    searchMode: SearchMode.off,
    imageGenMode: ImageGenMode.off,
  );
}

class _HeldParser extends FileParser {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Attachment> parseAsync({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return parse(
      name: name,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      bytes: bytes,
    );
  }
}

class _CaptureMedia extends FakeMediaProvider {
  _CaptureMedia({super.failuresRemaining});
  final requests = <({MediaApiConfig config, List<ImageEditReference> refs})>[];
  final entered = Completer<void>();
  Completer<void>? gate;
  @override
  Future<GeneratedImage> generateImage({
    required MediaApiConfig config,
    required String apiKey,
    required String prompt,
    CancelToken? cancelToken,
    List<int>? referenceImageBytes,
    String referenceMimeType = 'image/png',
    String referenceFileName = 'reference.png',
    List<ImageEditReference> referenceImages = const [],
  }) async {
    requests.add((config: config, refs: List.of(referenceImages)));
    if (!entered.isCompleted) entered.complete();
    if (gate != null) await gate!.future;
    final generated = await super.generateImage(
      config: config,
      apiKey: apiKey,
      prompt: prompt,
      cancelToken: cancelToken,
      referenceImages: referenceImages,
    );
    return GeneratedImage(
      base64: generated.base64,
      revisedPrompt: 'API revision',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late LibraryFileStore files;
  late LibraryRepository library;
  late ProjectRepository projects;
  late GenerationRepository generations;
  late _Memory memory;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('expert-chat-project-test-');
    db = AppDatabase(NativeDatabase.memory());
    files = LibraryFileStore(rootOverride: temp.path);
    library = LibraryRepository(db, files);
    projects = ProjectRepository(db, library, FileParser());
    generations = GenerationRepository(db, library);
    memory = _Memory();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  Future<ProviderContainer> container(
    FakeLlmProvider llm, {
    FakeMediaProvider? media,
    FileParser? parser,
  }) async {
    final value = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        libraryFileStoreProvider.overrideWithValue(files),
        memoryStoreProvider.overrideWithValue(memory),
        llmProvider.overrideWithValue(llm),
        settingsControllerProvider.overrideWith(_Settings.new),
        if (media != null) mediaApiProvider.overrideWithValue(media),
        if (parser != null) fileParserProvider.overrideWithValue(parser),
      ],
    );
    addTearDown(value.dispose);
    await value.read(chatControllerProvider.future);
    return value;
  }

  Future<String> project({
    String name = '项目 A',
    String instructions = 'PROJECT_A',
  }) => projects.save(name: name, instructions: instructions, fileIds: []);

  test(
    'project ID survives DTO, summary, placeholder saves and deletion detaches only',
    () async {
      final id = await project();
      final c = Conversation(
        projectId: id,
        messages: [ChatMessage(role: MessageRole.user, content: '保留')],
      );
      expect(Conversation.fromJson(c.toJson()).projectId, id);
      expect(c.copyWith(title: 'x').projectId, id);
      expect(c.copyWith(projectId: null).projectId, isNull);
      final repo = DriftConversationRepository(db);
      await repo.saveConversation(c);
      final summary = (await repo.loadSummaries()).single;
      expect(summary.projectId, id);
      await repo.saveConversation(
        summary.toPlaceholder().copyWith(title: '重命名'),
      );
      expect((await repo.loadConversation(c.id)).messages, hasLength(1));
      await projects.delete(id);
      final detached = await repo.loadConversation(c.id);
      expect(detached.projectId, isNull);
      expect(detached.messages, hasLength(1));
    },
  );

  test(
    'memory scope persists and cannot recall or replace another project',
    () async {
      final repo = MemoryRepository(memory);
      await repo.add(content: '全局背景');
      final a = await repo.add(content: '相同项目事实', projectId: 'a');
      final b = await repo.add(content: '相同项目事实', projectId: 'b');
      expect(a.created && b.created, isTrue);
      final decoded = const MemoryMarkdownCodec().decode(memory.value);
      expect(decoded.entries.last.projectId, 'b');
      expect(
        (await repo.recall(
          '',
          projectId: 'a',
        )).entries.map((e) => e.projectId).toSet(),
        {null, 'a'},
      );
      expect((await repo.recall('')).entries.map((e) => e.projectId).toSet(), {
        null,
      });
      final changed = await repo.replace(
        replacedIds: [b.entry.id],
        content: '不能覆盖',
        projectId: 'a',
      );
      expect(changed.applied, isFalse);
      final merged = await repo.mergeImport(
        additions: [b.entry.copyWith(content: '新事实')],
        replacements: [],
      );
      expect(merged.skipped, 1); // Same ID, not a silently duplicated entry.
    },
  );

  test(
    'project snapshot reports truncation and missing bytes without reading other projects',
    () async {
      final item = await library.importBytes(
        name: 'readme.txt',
        mimeType: 'text/plain',
        bytes: Uint8List.fromList(utf8.encode('a' * 40000)),
      );
      final id = await projects.save(
        name: 'A',
        instructions: '说明',
        fileIds: [item.id],
      );
      final snapshot = await projects.context(id);
      expect(snapshot.prompt, contains('已截断'));
      expect(snapshot.sources, ['readme.txt']);
      await files.delete(item.relativePath);
      expect((await projects.context(id)).prompt, contains('文件缺失'));
      await projects.delete(id);
      expect(await library.getById(item.id), isNotNull);
    },
  );

  test(
    'request freezes project instructions and memory scope while UI switches',
    () async {
      final parser = _HeldParser();
      final item = await library.importBytes(
        name: 'note.txt',
        mimeType: 'text/plain',
        bytes: Uint8List.fromList(utf8.encode('DOCUMENT_A')),
      );
      final a = await projects.save(
        name: 'A',
        instructions: 'OLD_PROJECT_A',
        fileIds: [item.id],
      );
      final b = await project(name: 'B', instructions: 'PRIVATE_B');
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: '回答')]);
      final ref = await container(llm, parser: parser);
      await ref
          .read(memoryRepositoryProvider)
          .add(content: 'MEMORY_A', projectId: a);
      await ref
          .read(memoryRepositoryProvider)
          .add(content: 'SECRET_MEMORY_B', projectId: b);
      final controller = ref.read(chatControllerProvider.notifier);
      controller.newConversation(projectId: a);
      final run = controller.sendMessage('解释资料');
      await parser.entered.future;
      await projects.save(
        id: a,
        name: 'A',
        instructions: 'NEW_PROJECT_A',
        fileIds: [item.id],
      );
      controller.newConversation(projectId: b);
      parser.release.complete();
      await run;
      final sent = llm.calls.expand((c) => c).map((m) => m.content).join();
      expect(sent, contains('OLD_PROJECT_A'));
      expect(sent, contains('DOCUMENT_A'));
      expect(sent, contains('MEMORY_A'));
      expect(sent, isNot(contains('SECRET_MEMORY_B')));
      expect(sent, isNot(contains('NEW_PROJECT_A')));
      expect(sent, isNot(contains('PRIVATE_B')));
    },
  );

  test(
    'generation versions share bytes but retain separate parameters and lineage',
    () async {
      const config = MediaApiConfig(
        baseUrl: 'https://user:secret@media.example/v1?token=secret',
        model: 'image-model',
      );
      final output = Attachment(
        name: 'x.png',
        mimeType: 'image/png',
        sizeBytes: 4,
        imageBase64: 'QUFBQQ==',
      );
      final one = await generations.record(
        output: output,
        config: config,
        originalPrompt: '原始',
        sentPrompt: '优化一',
        conversationId: 'c',
        messageId: 'm',
      );
      final two = await generations.record(
        output: output,
        config: config,
        originalPrompt: '原始',
        sentPrompt: '优化二',
        conversationId: 'c',
        messageId: 'n',
        parentGenerationId: one,
      );
      final first = (await generations.get(one))!;
      final second = (await generations.get(two))!;
      expect(first.libraryItemId, second.libraryItemId);
      expect(second.parentGenerationId, one);
      expect(first.providerHost, 'https://media.example');
      expect(first.apiFormat, LlmApiFormat.openAiCompatible.wire);
      await library.delete(first.libraryItemId!);
      expect((await generations.list()), hasLength(2));
      expect((await generations.get(one))!.libraryItemId, isNull);
    },
  );

  test(
    'reference provenance checks missing file and hash before replay',
    () async {
      final id = await generations.record(
        output: Attachment(
          name: 'remote.png',
          mimeType: 'image/png',
          sizeBytes: 0,
          remoteUrl: 'https://example.com/x',
        ),
        config: const MediaApiConfig(model: 'model'),
        originalPrompt: 'x',
        sentPrompt: 'x',
        conversationId: 'c',
        messageId: 'm',
        references: [
          const ImageEditReference(bytes: [1, 2, 3]),
        ],
      );
      final record = (await generations.get(id))!;
      expect((await generations.references(record)).single.imageBase64, 'AQID');
      final item = (await library.list()).single;
      await files.delete(item.relativePath);
      await expectLater(generations.references(record), throwsStateError);
    },
  );

  test(
    'confirmed replay skips optimizer, preserves exact sent prompt and creates parent link',
    () async {
      final llm = FakeLlmProvider([]);
      final media = FakeMediaProvider();
      final ref = await container(llm, media: media);
      final controller = ref.read(chatControllerProvider.notifier);
      controller.newConversation();
      await controller.generateImage('蓝色的小鸟');
      final first = (await generations.list()).single;
      await controller.regenerateImageVersion(first);
      final all = await generations.list();
      expect(all, hasLength(2));
      expect(all.where((r) => r.parentGenerationId == first.id), hasLength(1));
      expect(media.prompts, [first.optimizedPrompt, first.optimizedPrompt]);
      expect(llm.calls, isEmpty);
      expect(
        ImagePromptSafety.freeform(first.optimizedPrompt),
        first.optimizedPrompt,
      );
    },
  );

  test(
    'multi-reference edits preserve sent parameters and archived bytes on version replay',
    () async {
      final llm = FakeLlmProvider(const [
        ChatChunk(contentDelta: 'refined forest'),
      ]);
      final media = _CaptureMedia();
      final c = await container(llm, media: media);
      final controller = c.read(chatControllerProvider.notifier);
      final settings = c.read(settingsControllerProvider.notifier);
      await c.read(settingsControllerProvider.future);
      await settings.setMediaApiConfig(
        MediaApiKind.imageGeneration,
        const MediaApiConfig(
          baseUrl: 'https://media.example/v1',
          model: 'gpt-image-1',
          imageSize: '1536x1024',
        ),
      );
      final refs = [
        Attachment(name: 'a.jpg', mimeType: 'image/jpeg', imageBase64: 'AQID'),
        Attachment(name: 'b.png', mimeType: 'image/png', imageBase64: 'BAUG'),
      ];
      controller.toggleDeepThink();
      await controller.generateImage('original scene', referenceImages: refs);
      final first = (await generations.list()).single;
      expect(first.originalPrompt, 'original scene');
      expect(
        first.optimizedPrompt,
        ImagePromptSafety.freeform('refined forest'),
      );
      expect(first.revisedPrompt, 'API revision');
      expect(first.model, 'gpt-image-1');
      expect(media.requests.single.refs.map((r) => r.fileName), [
        'a.jpg',
        'b.png',
      ]);
      expect(media.requests.single.refs.map((r) => r.bytes), [
        [1, 2, 3],
        [4, 5, 6],
      ]);
      await settings.setMediaApiConfig(
        MediaApiKind.imageGeneration,
        const MediaApiConfig(
          baseUrl: 'https://media.example/v1',
          model: 'gpt-image-2',
          imageSize: '1024x1024',
        ),
      );
      await controller.regenerateImageVersion(first);
      final next = (await generations.list()).singleWhere(
        (r) => r.parentGenerationId == first.id,
      );
      expect(llm.calls, hasLength(1), reason: '版本重放不再次优化');
      expect(media.requests.last.config.model, first.model);
      expect(media.requests.last.config.imageSize, first.imageSize);
      expect(media.prompts, [first.optimizedPrompt, first.optimizedPrompt]);
      expect(media.requests.last.refs.map((r) => r.bytes), [
        [1, 2, 3],
        [4, 5, 6],
      ]);
      expect(media.requests.last.refs.map((r) => r.fileName), [
        'a.jpg',
        'b.png',
      ]);
      expect(next.originalPrompt, first.originalPrompt);
      expect(next.optimizedPrompt, first.optimizedPrompt);
      expect(next.messageId, isNot(first.messageId));
      final answer = c
          .read(chatControllerProvider)
          .requireValue
          .current!
          .activePath
          .last;
      expect(next.messageId, answer.id);
      expect(answer.content, contains('图生图'));
    },
  );

  for (final originalFormat in [
    LlmApiFormat.geminiNative,
    LlmApiFormat.openAiCompatible,
  ]) {
    test(
      'version replay restores $originalFormat after same-origin protocol changes',
      () async {
        final media = _CaptureMedia();
        final c = await container(FakeLlmProvider([]), media: media);
        final controller = c.read(chatControllerProvider.notifier);
        final settings = c.read(settingsControllerProvider.notifier);
        await c.read(settingsControllerProvider.future);
        final original = MediaApiConfig(
          baseUrl: 'https://media.example/v1beta',
          model: 'gemini-2.5-flash-image',
          apiFormat: originalFormat == LlmApiFormat.geminiNative
              ? LlmApiFormat.auto
              : originalFormat,
        );
        await settings.setMediaApiConfig(
          MediaApiKind.imageGeneration,
          original,
        );
        expect(await controller.generateImage('蓝色的小鸟'), isTrue);
        final first = (await generations.list()).single;
        expect(
          first.apiFormat,
          originalFormat.wire,
          reason: 'Record the resolved protocol, never auto',
        );
        final otherFormat = originalFormat == LlmApiFormat.geminiNative
            ? LlmApiFormat.openAiCompatible
            : LlmApiFormat.geminiNative;
        await settings.setMediaApiConfig(
          MediaApiKind.imageGeneration,
          original.copyWith(apiFormat: otherFormat),
        );
        expect(await controller.regenerateImageVersion(first), isTrue);
        expect(media.requests.last.config.apiFormat, originalFormat);
        expect(media.requests.last.config.effectiveApiFormat, originalFormat);
        final next = (await generations.list()).singleWhere(
          (r) => r.parentGenerationId == first.id,
        );
        expect(next.apiFormat, originalFormat.wire);
        expect(
          c
              .read(settingsControllerProvider)
              .requireValue
              .imageGenerationApi
              .apiFormat,
          otherFormat,
          reason: 'Replaying a version must not change the current settings',
        );
      },
    );
  }

  test(
    'legacy version uses current protocol and unknown protocol does not silently fall back',
    () async {
      final media = _CaptureMedia();
      final c = await container(FakeLlmProvider([]), media: media);
      final controller = c.read(chatControllerProvider.notifier);
      final settings = c.read(settingsControllerProvider.notifier);
      await c.read(settingsControllerProvider.future);
      const config = MediaApiConfig(
        baseUrl: 'https://media.example/v1beta',
        model: 'gemini-2.5-flash-image',
        apiFormat: LlmApiFormat.geminiNative,
      );
      await settings.setMediaApiConfig(MediaApiKind.imageGeneration, config);
      expect(await controller.generateImage('蓝色的小鸟'), isTrue);
      final first = (await generations.list()).single;
      await db.customStatement(
        'UPDATE generation_records SET api_format = NULL WHERE id = ?',
        [first.id],
      );
      final legacy = (await generations.get(first.id))!;
      await settings.setMediaApiConfig(
        MediaApiKind.imageGeneration,
        config.copyWith(apiFormat: LlmApiFormat.openAiCompatible),
      );
      expect(await controller.regenerateImageVersion(legacy), isTrue);
      expect(
        media.requests.last.config.apiFormat,
        LlmApiFormat.openAiCompatible,
      );
      expect(
        (await generations.list())
            .singleWhere((r) => r.parentGenerationId == first.id)
            .apiFormat,
        LlmApiFormat.openAiCompatible.wire,
      );

      await db.customStatement(
        'UPDATE generation_records SET api_format = ? WHERE id = ?',
        ['futureProtocol', first.id],
      );
      await expectLater(
        controller.regenerateImageVersion((await generations.get(first.id))!),
        throwsArgumentError,
      );
      expect(media.requests, hasLength(2));
      expect(await generations.list(), hasLength(2));
    },
  );

  for (final cancel in [false, true]) {
    test(
      'image response after switching conversations preserves ownership with cancellation=$cancel',
      () async {
        final media = _CaptureMedia()..gate = Completer<void>();
        final c = await container(FakeLlmProvider(const []), media: media);
        final controller = c.read(chatControllerProvider.notifier);
        final running = controller.generateImage('forest');
        await media.entered.future;
        final origin = c.read(chatControllerProvider).requireValue.currentId;
        controller.newConversation();
        final selected = c.read(chatControllerProvider).requireValue.currentId;
        expect(selected, isNot(origin));
        if (cancel) controller.stop();
        media.gate!.complete();
        await running;
        final state = c.read(chatControllerProvider).requireValue;
        expect(state.currentId, selected);
        expect(state.current!.messages, isEmpty);
        final old = state.conversations.singleWhere(
          (item) => item.id == origin,
        );
        final records = await generations.list();
        if (cancel) {
          expect(old.activePath.last.attachments, isEmpty);
          expect(records, isEmpty);
        } else {
          expect(old.activePath.last.attachments, hasLength(1));
          expect(records.single.conversationId, origin);
          expect(records.single.messageId, old.activePath.last.id);
        }
      },
    );
  }

  test(
    'invalid references never reach the media API and retain an image retry operation',
    () async {
      final media = _CaptureMedia();
      final c = await container(FakeLlmProvider(const []), media: media);
      final controller = c.read(chatControllerProvider.notifier);
      await controller.generateImage(
        'edit',
        referenceImages: [
          Attachment(
            name: 'bad.png',
            mimeType: 'image/png',
            imageBase64: '%%%',
          ),
        ],
      );
      final state = c.read(chatControllerProvider).requireValue;
      expect(media.requests, isEmpty);
      expect(state.error, contains('数据无效'));
      expect(state.retryOperation?.kind, ChatRetryKind.image);
      expect(state.current!.activePath.last.attachments, isEmpty);
      expect(await generations.list(), isEmpty);
    },
  );

  test(
    'failed image edit retries its reference bytes and creates only one version record',
    () async {
      final media = _CaptureMedia(failuresRemaining: 1);
      final c = await container(FakeLlmProvider(const []), media: media);
      final controller = c.read(chatControllerProvider.notifier);
      await controller.generateImage(
        'edit',
        referenceImages: [
          Attachment(name: 'a.png', mimeType: 'image/png', imageBase64: 'AQID'),
        ],
      );
      expect(await generations.list(), isEmpty);
      await controller.retryLast();
      expect(media.requests, hasLength(2));
      expect(media.requests.first.refs.single.bytes, [1, 2, 3]);
      expect(media.requests.last.refs.single.bytes, [1, 2, 3]);
      expect(await generations.list(), hasLength(1));
      expect(c.read(chatControllerProvider).requireValue.error, isNull);
    },
  );

  test('concurrent duplicate library imports remain single-row', () async {
    final results = await Future.wait(
      List.generate(
        8,
        (_) => library.importBytes(
          name: 'same.txt',
          mimeType: 'text/plain',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ),
    );
    expect(results.map((i) => i.id).toSet(), hasLength(1));
    expect(await library.list(), hasLength(1));
  });
}
