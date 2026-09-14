import 'dart:async';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/domain/media/image_edit_reference.dart';
import 'package:expert_chat/domain/media/image_prompt_safety.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';
import 'package:expert_chat/domain/tools/dialogue_image_executor.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = MediaApiConfig(
  baseUrl: 'https://image.example',
  model: 'image',
);

class _Media extends OpenAiCompatibleMediaProvider {
  final prompts = <String>[];
  Future<GeneratedImage> Function() response = () async =>
      const GeneratedImage(base64: 'QUFBQQ==', revisedPrompt: 'API revision');
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
  }) {
    expect(config, same(_config));
    expect(apiKey, 'test');
    expect(referenceImages, isEmpty);
    expect(referenceImageBytes, isNull);
    prompts.add(prompt);
    return response();
  }
}

void main() {
  late _Media media;
  late List<SearchActivity> activities;
  late List<bool> generating;
  late List<DialogueImageOutput> outputs;
  late bool active;
  late bool allowed;
  late int budgetChecks;
  late DialogueImageExecutor executor;
  setUp(() {
    media = _Media();
    activities = [];
    generating = [];
    outputs = [];
    active = true;
    allowed = true;
    budgetChecks = 0;
    executor = DialogueImageExecutor(
      getProvider: () => media,
      isActive: () => active,
      checkBudget: () {
        budgetChecks++;
        return (allowed: allowed, reason: '预算耗尽');
      },
      onActivity: activities.add,
      onGeneratingChanged: generating.add,
      onGenerated: (output) async => outputs.add(output),
    );
  });
  Future<({bool ok, String? error})> run({
    MediaApiConfig? config = _config,
    CharacterCard? character,
    String? modelPrompt = 'a forest',
    String userText = 'user description',
    CancelToken? token,
    bool countTool = true,
    Future<String> Function(String)? optimize,
  }) => executor.execute(
    config: config,
    apiKey: 'test',
    character: character,
    userText: userText,
    modelPrompt: modelPrompt,
    briefHint: 'smiling',
    cancelToken: token ?? CancelToken(),
    countTool: countTool,
    optimizePrompt: optimize,
  );

  test(
    'ordinary generation prepares prompt and delivers image metadata before completion',
    () async {
      expect((await run()).ok, isTrue);
      expect(media.prompts.single, ImagePromptSafety.freeform('a forest'));
      expect(outputs.single.sentPrompt, media.prompts.single);
      expect(outputs.single.revisedPrompt, 'API revision');
      expect(outputs.single.attachment.imageBase64, 'QUFBQQ==');
      expect(outputs.single.attachment.sizeBytes, 6);
      expect(outputs.single.attachment.name, endsWith('.png'));
      expect(generating, [true, false]);
      expect(activities.first.id, activities.last.id);
      expect(
        activities.last.items.single.title,
        outputs.single.attachment.name,
      );
      expect(activities.last.status, SearchActivityStatus.done);
    },
  );

  test('portrait uses the card and skips freeform optimization', () async {
    final card = CharacterCard(name: '青禾', description: '青衣长发');
    await run(
      character: card,
      userText: 'USER_ONLY',
      modelPrompt: 'MODEL_ONLY',
      optimize: (_) async => throw StateError('must not optimize portrait'),
    );
    expect(
      media.prompts.single,
      ImagePromptSafety.characterPortrait(card, userHint: 'smiling'),
    );
    expect(media.prompts.single, isNot(contains('USER_ONLY')));
    expect(media.prompts.single, isNot(contains('MODEL_ONLY')));
  });

  test(
    'optimization failure falls back and success sanitizes the refinement',
    () async {
      await run(
        modelPrompt: null,
        optimize: (prompt) async {
          expect(prompt, ImagePromptSafety.freeform('user description'));
          throw StateError('optimizer unavailable');
        },
      );
      expect(
        media.prompts.single,
        ImagePromptSafety.freeform('user description'),
      );
      expect(activities[1].error, '提示词优化未完成，使用原始描述');
      await run(optimize: (_) async => 'a sunny forest');
      expect(media.prompts.last, ImagePromptSafety.freeform('a sunny forest'));
    },
  );

  test(
    'configuration and budget rejection avoid requests; tool path avoids duplicate charging',
    () async {
      expect((await run(config: null)).ok, isFalse);
      expect(budgetChecks, 0);
      allowed = false;
      expect((await run()).error, '预算耗尽');
      expect(media.prompts, isEmpty);
      expect(activities, isEmpty);
      expect((await run(countTool: false)).ok, isTrue);
      expect(budgetChecks, 1);
    },
  );

  test(
    'cancellation during optimization never calls the image service',
    () async {
      final token = CancelToken();
      final result = await run(
        token: token,
        optimize: (_) async {
          token.cancel();
          return 'late prompt';
        },
      );
      expect(result.ok, isFalse);
      expect(result.error, isNull);
      expect(media.prompts, isEmpty);
      expect(outputs, isEmpty);
      expect(activities.last.error, '已取消');
    },
  );

  for (final cancelToken in [true, false]) {
    test(
      'late image is discarded after ${cancelToken ? 'cancellation' : 'leaving active execution'}',
      () async {
        final entered = Completer<void>();
        final response = Completer<GeneratedImage>();
        media.response = () {
          entered.complete();
          return response.future;
        };
        final token = CancelToken();
        final running = run(token: token);
        await entered.future;
        if (cancelToken) {
          token.cancel();
        } else {
          active = false;
        }
        response.complete(const GeneratedImage(base64: 'QUFBQQ=='));
        expect((await running).ok, isFalse);
        expect(outputs, isEmpty);
        expect(activities.last.error, '已取消');
        expect(generating.last, isFalse);
      },
    );
  }

  test(
    'provider failure can retry and remote-only images preserve their URL',
    () async {
      media.response = () async => throw StateError('offline');
      final failed = await run();
      expect(failed.error, contains('offline'));
      expect(outputs, isEmpty);
      expect(generating.last, isFalse);
      media.response = () async => const GeneratedImage(
        remoteUrl: 'https://example.com/pic.webp',
        mimeType: 'image/webp',
      );
      expect((await run()).ok, isTrue);
      expect(
        outputs.single.attachment.remoteUrl,
        'https://example.com/pic.webp',
      );
      expect(outputs.single.attachment.sizeBytes, 0);
      expect(outputs.single.attachment.name, endsWith('.webp'));
    },
  );

  test('tool arguments preserve aliases and malformed input fallback', () {
    expect(DialogueImageExecutor.parseToolArgs('{'), (
      prompt: null,
      briefHint: null,
    ));
    expect(
      DialogueImageExecutor.parseToolArgs(
        '{"prompt":"  forest  ","briefHint":" smile "}',
      ),
      (prompt: 'forest', briefHint: 'smile'),
    );
  });
}
