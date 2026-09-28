import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/media/image_codec_util.dart';
import 'package:expert_chat/domain/media/image_generation_service.dart';
import 'package:expert_chat/domain/media/image_prompt_optimizer.dart';
import 'package:expert_chat/domain/media/image_reference_preparer.dart';
import 'package:flutter_test/flutter_test.dart';

Attachment _image(String name, List<int> bytes) => Attachment(
  name: name,
  mimeType: 'image/jpeg',
  imageBase64: base64Encode(bytes),
);

class _Optimizer extends LlmProvider {
  List<LlmRequestMessage>? sent;
  bool cancelAfterReasoning = false;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    expect(thinking, isTrue);
    expect(reasoningEffort, ReasoningEffort.low);
    expect(tools, isNull);
    sent = messages;
    yield const ChatChunk(reasoningDelta: '考虑构图');
    if (cancelAfterReasoning) cancelToken!.cancel();
    yield const ChatChunk(contentDelta: '```text\n"a bright forest"\n```');
  }
}

void main() {
  test(
    'reference preparation preserves order and forwards resized names and MIME types',
    () async {
      final resized = <String>[];
      final preparer = ImageReferencePreparer(
        prepareImage: (bytes, {required mimeType, required name}) async {
          resized.add(name);
          return PreparedReferenceImage(
            bytes: Uint8List.fromList([...bytes, 9]),
            mimeType: 'image/png',
            name: '$name.png',
          );
        },
      );
      final result = await preparer.prepare(
        [
          _image('a.jpg', [1]),
          _image('b.jpg', [2]),
        ],
        preserveOriginalBytes: false,
        isActive: () => true,
      );
      expect(result.error, isNull);
      expect(resized, ['a.jpg', 'b.jpg']);
      expect(result.references.map((r) => r.fileName), [
        'a.jpg.png',
        'b.jpg.png',
      ]);
      expect(result.references.map((r) => r.mimeType), [
        'image/png',
        'image/png',
      ]);
      expect(result.references.map((r) => r.bytes), [
        [1, 9],
        [2, 9],
      ]);
      expect(() => result.references.clear(), throwsUnsupportedError);
    },
  );

  test(
    'version replay bypasses resize and preserves archived bytes and names',
    () async {
      final preparer = ImageReferencePreparer(
        prepareImage: (bytes, {required mimeType, required name}) async =>
            throw StateError('Do not resize a replay'),
      );
      final result = await preparer.prepare(
        [
          _image('original.jpg', [1, 2, 3]),
        ],
        preserveOriginalBytes: true,
        isActive: () => true,
      );
      expect(result.references.single.bytes, [1, 2, 3]);
      expect(result.references.single.fileName, 'original.jpg');
      expect(result.references.single.mimeType, 'image/jpeg');
    },
  );

  test(
    'invalid or remote-only reference returns its existing actionable error',
    () async {
      final preparer = const ImageReferencePreparer();
      for (final attachment in [
        Attachment(
          name: 'remote.png',
          mimeType: 'image/png',
          remoteUrl: 'https://example.com/a',
        ),
        Attachment(name: 'bad.png', mimeType: 'image/png', imageBase64: '%%%'),
      ]) {
        final result = await preparer.prepare(
          [attachment],
          preserveOriginalBytes: false,
          isActive: () => true,
        );
        expect(result.references, isEmpty);
        expect(result.error, contains(attachment.name));
        expect(result.error, contains('请重新'));
        expect(result.cancelled, isFalse);
      }
    },
  );

  test(
    'stop during decoding skips resizing and all later references',
    () async {
      var active = true;
      var decodes = 0;
      final decoded = Completer<Uint8List>();
      final preparer = ImageReferencePreparer(
        decode: (_) {
          decodes++;
          return decoded.future;
        },
        prepareImage: (bytes, {required mimeType, required name}) async =>
            throw StateError('Should be cancelled before resize'),
      );
      final running = preparer.prepare(
        [
          _image('a.jpg', [1]),
          _image('b.jpg', [2]),
        ],
        preserveOriginalBytes: false,
        isActive: () => active,
      );
      active = false;
      decoded.complete(Uint8List.fromList([1]));
      final result = await running;
      expect(result.cancelled, isTrue);
      expect(result.references, isEmpty);
      expect(decodes, 1);
    },
  );

  test('stop during resize does not publish partial references', () async {
    var active = true;
    final entered = Completer<void>();
    final scaled = Completer<PreparedReferenceImage>();
    final preparer = ImageReferencePreparer(
      prepareImage: (bytes, {required mimeType, required name}) {
        entered.complete();
        return scaled.future;
      },
    );
    final running = preparer.prepare(
      [
        _image('a.jpg', [1]),
      ],
      preserveOriginalBytes: false,
      isActive: () => active,
    );
    await entered.future;
    active = false;
    scaled.complete(
      PreparedReferenceImage(
        bytes: Uint8List(1),
        mimeType: 'image/png',
        name: 'a.png',
      ),
    );
    expect((await running).cancelled, isTrue);
  });

  test(
    'large base64 path preserves bytes across background decoding',
    () async {
      final original = Uint8List.fromList(
        List.generate(200000, (i) => i % 256),
      );
      expect(
        await ImageReferencePreparer.decodeBase64(base64Encode(original)),
        original,
      );
    },
  );

  for (final cancelled in [false, true]) {
    test(
      'optimizer separates reasoning and cleaned prompt with cancellation=$cancelled',
      () async {
        final provider = _Optimizer()..cancelAfterReasoning = cancelled;
        final reasoning = <String>[];
        final prompt = await ImagePromptOptimizer(getProvider: () => provider)
            .optimize(
              userPrompt: '原始画面',
              config: const LlmConfig(
                baseUrl: 'https://example.com',
                apiKey: 'test',
                model: 'test',
              ),
              cancelToken: CancelToken(),
              onReasoning: (text, millis) => reasoning.add(text),
            );
        expect(prompt, cancelled ? '' : 'a bright forest');
        expect(reasoning.last, '考虑构图');
        expect(provider.sent!.last.content, '原始画面');
        expect(provider.sent!.first.content, ImagePromptOptimizer.systemPrompt);
      },
    );
  }

  test('result display distinguishes optimizer output and API revision', () {
    expect(
      ImageGenerationService.resultContent(
        originalPrompt: 'original',
        optimizedByModel: 'optimized',
        revisedByApi: 'revised',
        usedReferenceImage: true,
      ),
      '图片已生成（图生图）\n\n深度思考优化后的提示词：optimized\n\n生图接口改写：revised',
    );
    expect(
      ImageGenerationService.resultContent(
        originalPrompt: 'same',
        optimizedByModel: '',
        revisedByApi: 'same',
      ),
      '图片已生成\n\n优化后的提示词：same',
    );
  });
}
