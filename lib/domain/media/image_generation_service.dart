import 'package:dio/dio.dart';

import '../../data/library_models.dart';
import '../../data/media_api_config.dart';
import '../../data/models.dart';
import 'image_edit_reference.dart';
import 'openai_compatible_media_provider.dart';

class ImageGenerationResult {
  ImageGenerationResult({required this.sentPrompt, required this.response});
  final String sentPrompt;
  final GeneratedImage response;
  String? get revisedPrompt => response.revisedPrompt;

  // Materialize only after the caller checks cancellation, as before.
  late final Attachment attachment = Attachment(
    name: libraryGeneratedImageName(
      prompt: sentPrompt,
      mimeType: response.mimeType,
    ),
    mimeType: response.mimeType,
    sizeBytes: response.base64 == null
        ? 0
        : (response.base64!.length * 3 / 4).round(),
    imageBase64: response.base64,
    remoteUrl: response.remoteUrl,
  );
}

/// One request path for ordinary generation and edits, preserving reference order.
class ImageGenerationService {
  const ImageGenerationService({required this.getProvider});
  final OpenAiCompatibleMediaProvider Function() getProvider;

  Future<ImageGenerationResult> generate({
    required MediaApiConfig config,
    required String apiKey,
    required String prompt,
    required CancelToken cancelToken,
    List<ImageEditReference> references = const [],
  }) async => ImageGenerationResult(
    sentPrompt: prompt,
    response: await getProvider().generateImage(
      config: config,
      apiKey: apiKey,
      prompt: prompt,
      cancelToken: cancelToken,
      referenceImages: references,
    ),
  );

  static String resultContent({
    required String originalPrompt,
    required String optimizedByModel,
    String? revisedByApi,
    bool usedReferenceImage = false,
  }) {
    final parts = <String>[usedReferenceImage ? '图片已生成（图生图）' : '图片已生成'];
    final opt = optimizedByModel.trim();
    final revised = revisedByApi?.trim() ?? '';
    if (opt.isNotEmpty && opt != originalPrompt.trim()) {
      parts.add('深度思考优化后的提示词：$opt');
    }
    if (revised.isNotEmpty &&
        revised != opt &&
        revised != originalPrompt.trim()) {
      parts.add('生图接口改写：$revised');
    }
    if (parts.length == 1 && revised.isNotEmpty) {
      parts.add('优化后的提示词：$revised');
    }
    return parts.join('\n\n');
  }
}
