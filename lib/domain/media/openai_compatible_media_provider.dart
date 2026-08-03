import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart';

import '../../data/media_api_config.dart';
import 'image_edit_reference.dart';

class GeneratedImage {
  const GeneratedImage({
    this.base64,
    this.remoteUrl,
    this.mimeType = 'image/png',
    this.revisedPrompt,
  });

  final String? base64;
  final String? remoteUrl;
  final String mimeType;
  final String? revisedPrompt;
}

/// Audio returned by a configured cloud TTS provider.
///
/// The protocol decides the container: OpenAI-compatible TTS returns MP3
/// bytes, while MiMo returns Base64-encoded WAV in a chat-completion response.
class SynthesizedSpeech {
  const SynthesizedSpeech({
    required this.bytes,
    required this.fileExtension,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileExtension;
  final String mimeType;
}

/// Optional OpenAI-compatible image-generation and text-to-speech endpoints.
///
/// Vision chat itself keeps using [LlmProvider], because it is the same
/// `/chat/completions` protocol with multimodal message parts.
class OpenAiCompatibleMediaProvider {
  OpenAiCompatibleMediaProvider({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 3),
              sendTimeout: const Duration(minutes: 1),
            ),
          );

  final Dio _dio;

  static const int _maxAudioBytes = 25 * 1024 * 1024;
  static const int _maxBase64Chars = 32 * 1024 * 1024;
  static const int _maxImageDownloadBytes = 20 * 1024 * 1024;

  /// Cancel reason used when a TTS audio stream exceeds [_maxAudioBytes].
  /// The speech service tells this internal abort apart from a
  /// user-initiated stop by matching the reason.
  static const String ttsSizeLimitCancelReason = 'TTS 音频超过 25 MB 限制。';

  /// Cancel reason used when a generated-image URL download exceeds
  /// [_maxImageDownloadBytes]. The provider maps this internal abort to a
  /// content error, while a user-initiated cancel keeps its Dio semantics.
  static const String imageDownloadSizeLimitCancelReason = '图片超过 20 MB 限制。';

  /// Text-to-image (`/images/generations`) or image-to-image (`/images/edits`)
  /// when reference image(s) are provided (OpenAI-compatible multipart).
  ///
  /// Prefer [referenceImages] for multi-ref GPT Image models. The single
  /// [referenceImageBytes] fields remain for backward-compatible call sites.
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
    _ensureConfigured(config, apiKey, '生图');
    final refs = <ImageEditReference>[
      ...referenceImages.where((r) => r.bytes.isNotEmpty),
      if (referenceImages.isEmpty &&
          referenceImageBytes != null &&
          referenceImageBytes.isNotEmpty)
        ImageEditReference(
          bytes: referenceImageBytes,
          mimeType: referenceMimeType,
          fileName: referenceFileName,
        ),
    ];
    final maxRefs = config.maxImageEditReferences;
    final bounded = refs.length > maxRefs ? refs.sublist(0, maxRefs) : refs;
    if (bounded.isNotEmpty) {
      return _editImage(
        config: config,
        apiKey: apiKey,
        prompt: prompt,
        references: bounded,
        cancelToken: cancelToken,
      );
    }

    final response = await _postJson(
      _endpoint(config.baseUrl, 'images/generations'),
      apiKey: apiKey,
      body: {
        'model': config.model.trim(),
        'prompt': prompt.trim(),
        if (config.imageSize.trim().isNotEmpty) 'size': config.imageSize.trim(),
      },
      cancelToken: cancelToken,
      action: '生图',
    );
    return _parseGeneratedImageResponse(response, cancelToken: cancelToken);
  }

  /// OpenAI-compatible image edit / img2img via multipart `images/edits`.
  ///
  /// - Legacy single-image gateways: one part named `image`
  /// - GPT Image multi-ref: repeated parts named `image[]` (official curl form)
  Future<GeneratedImage> _editImage({
    required MediaApiConfig config,
    required String apiKey,
    required String prompt,
    required List<ImageEditReference> references,
    CancelToken? cancelToken,
  }) async {
    if (references.isEmpty) {
      throw const FormatException('图生图需要至少一张参考图。');
    }
    for (final ref in references) {
      if (ref.bytes.length > 20 * 1024 * 1024) {
        throw const FormatException('参考图超过 20 MB 限制。');
      }
    }

    // GPT Image multi-ref docs use repeated `image[]` parts; classic single
    // edits gateways expect one part named `image`.
    final imageField =
        config.supportsMultiReferenceImages ? 'image[]' : 'image';

    final form = FormData();
    form.fields.add(MapEntry('model', config.model.trim()));
    form.fields.add(MapEntry('prompt', prompt.trim()));
    if (config.imageSize.trim().isNotEmpty) {
      form.fields.add(MapEntry('size', config.imageSize.trim()));
    }
    for (var i = 0; i < references.length; i++) {
      form.files.add(
        MapEntry(imageField, _multipartImage(references[i], index: i)),
      );
    }

    try {
      final response = await _dio.post<dynamic>(
        _endpoint(config.baseUrl, 'images/edits'),
        data: form,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${apiKey.trim()}',
            'Accept': 'application/json',
            // Let Dio set multipart boundary; do not force application/json.
          },
        ),
        cancelToken: cancelToken,
      );
      final raw = response.data;
      Map<String, dynamic> map;
      if (raw is Map) {
        map = Map<String, dynamic>.from(raw);
      } else if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw const FormatException('图生图接口返回了无法识别的数据格式。');
        }
        map = Map<String, dynamic>.from(decoded);
      } else {
        throw const FormatException('图生图接口返回了无法识别的数据格式。');
      }
      return _parseGeneratedImageResponse(map, cancelToken: cancelToken);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw await _humanizeError(e, '图生图');
    }
  }

  MultipartFile _multipartImage(ImageEditReference ref, {required int index}) {
    var safeName =
        ref.fileName.trim().isEmpty ? 'reference_$index.png' : ref.fileName.trim();
    final mime = ref.mimeType.trim().isEmpty || !ref.mimeType.startsWith('image/')
        ? 'image/png'
        : ref.mimeType.trim();
    if (!safeName.contains('.')) {
      final ext = switch (mime) {
        'image/jpeg' || 'image/jpg' => 'jpg',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        _ => 'png',
      };
      safeName = '$safeName.$ext';
    }
    // Without an explicit contentType Dio sends application/octet-stream,
    // which several OpenAI-compatible gateways reject as "invalid image".
    return MultipartFile.fromBytes(
      ref.bytes is Uint8List ? ref.bytes as Uint8List : Uint8List.fromList(ref.bytes),
      filename: safeName,
      contentType: _mediaTypeOf(mime),
    );
  }

  Future<GeneratedImage> _parseGeneratedImageResponse(
    Map<String, dynamic> response, {
    CancelToken? cancelToken,
  }) async {
    final data = response['data'];
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw const FormatException('生图接口没有返回图片数据。');
    }
    final item = Map<String, dynamic>.from(data.first as Map);
    final revisedPrompt = item['revised_prompt'] as String?;
    final rawBase64 = item['b64_json'] as String?;
    if (rawBase64 != null && rawBase64.isNotEmpty) {
      final parsed = _parseBase64Image(rawBase64);
      return GeneratedImage(
        base64: parsed.$2,
        mimeType: parsed.$1,
        revisedPrompt: revisedPrompt,
      );
    }

    final rawUrl = item['url'] as String?;
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const FormatException('生图接口返回了无效的图片地址。');
    }
    // Embed bytes so the chat bubble does not depend on a short-lived CDN URL
    // (common with edits/generations gateways). If the download fails we fail
    // loudly instead of storing a URL that will 404 later - a silent "success"
    // that vanishes on reload is worse than a retryable error.
    try {
      final downloaded = await _dio.get<List<int>>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
        cancelToken: cancelToken,
        // Abort as soon as the stream passes the limit instead of buffering
        // a multi-hundred-MB response in memory (mobile OOM risk).
        onReceiveProgress: (received, total) {
          if (received > _maxImageDownloadBytes) {
            cancelToken?.cancel(imageDownloadSizeLimitCancelReason);
          }
        },
      );
      final bytes = downloaded.data;
      if (bytes != null &&
          bytes.isNotEmpty &&
          bytes.length <= _maxImageDownloadBytes) {
        return GeneratedImage(
          base64: base64Encode(bytes),
          mimeType: _mimeFromUrlOrBytes(uri.toString(), bytes),
          remoteUrl: uri.toString(),
          revisedPrompt: revisedPrompt,
        );
      }
      throw const FormatException('图片已生成，但返回数据为空或过大，请重试。');
    } on FormatException {
      rethrow;
    } on DioException catch (e) {
      // Preserve cancellation semantics so the controller can tell a user
      // cancel apart from a real download failure. Our own size-limit abort
      // is a cancel at the Dio level too, so match its reason and report it
      // as a content error before falling through to the rethrow.
      if (e.error == imageDownloadSizeLimitCancelReason) {
        throw const FormatException('图片已生成，但返回数据为空或过大，请重试。');
      }
      if (CancelToken.isCancel(e)) rethrow;
      throw const FormatException('图片已生成，但下载图片数据失败，请重试。');
    } catch (_) {
      throw const FormatException('图片已生成，但下载图片数据失败，请重试。');
    }
  }

  /// `image/…` is already guaranteed by the caller, but a malformed subtype
  /// (`image/`, `image/x y`) would make [DioMediaType.parse] throw mid-upload.
  DioMediaType _mediaTypeOf(String mime) {
    try {
      return DioMediaType.parse(mime);
    } on FormatException {
      return DioMediaType('image', 'png');
    }
  }

  String _mimeFromUrlOrBytes(String url, List<int> bytes) {
    final lower = url.toLowerCase();
    if (lower.contains('.jpg') || lower.contains('.jpeg')) return 'image/jpeg';
    if (lower.contains('.webp')) return 'image/webp';
    if (lower.contains('.gif')) return 'image/gif';
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    return 'image/png';
  }

  /// Synthesizes speech using the configured wire protocol.
  ///
  /// MiMo speech is OpenAI *chat* compatible rather than compatible with the
  /// `/audio/speech` endpoint, so it must be handled as a separate protocol.
  ///
  /// [voiceSampleBytes] is required for `mimo-v2.5-tts-voiceclone` when the
  /// sample is not already inlined as a data URI in [MediaApiConfig.voice].
  Future<SynthesizedSpeech> synthesizeSpeech({
    required MediaApiConfig config,
    required String apiKey,
    required String text,
    double? speed,
    CancelToken? cancelToken,
    Uint8List? voiceSampleBytes,
    String voiceSampleMimeType = 'audio/wav',
  }) async {
    _ensureConfigured(config, apiKey, 'TTS');
    // Use effectiveSpeechProtocol so a MiMo base URL / model still works when
    // the saved protocol was left at the OpenAI default (a common setup miss).
    return switch (config.effectiveSpeechProtocol) {
      SpeechApiProtocol.openAiAudio => _synthesizeOpenAiSpeech(
        config: config,
        apiKey: apiKey,
        text: text,
        speed: speed,
        cancelToken: cancelToken,
      ),
      SpeechApiProtocol.mimoChatCompletions => _synthesizeMimoSpeech(
        config: config,
        apiKey: apiKey,
        text: text,
        speed: speed,
        cancelToken: cancelToken,
        voiceSampleBytes: voiceSampleBytes,
        voiceSampleMimeType: voiceSampleMimeType,
      ),
      SpeechApiProtocol.aliyunModelStudio => _synthesizeAliyunSpeech(
        config: config,
        apiKey: apiKey,
        text: text,
        speed: speed,
        cancelToken: cancelToken,
      ),
    };
  }

  Future<SynthesizedSpeech> _synthesizeOpenAiSpeech({
    required MediaApiConfig config,
    required String apiKey,
    required String text,
    double? speed,
    CancelToken? cancelToken,
  }) async {
    final normalizedSpeed = speed?.clamp(0.25, 4.0).toDouble();
    try {
      final response = await _dio.post<List<int>>(
        _endpoint(config.baseUrl, 'audio/speech'),
        data: jsonEncode({
          'model': config.model.trim(),
          'input': text.trim(),
          'voice': config.voice.trim().isEmpty ? 'alloy' : config.voice.trim(),
          'response_format': 'mp3',
          // `speed` is part of the OpenAI-compatible TTS schema. Omit the
          // default so older gateways that have not adopted it still work.
          if (normalizedSpeed != null && normalizedSpeed != 1.0)
            'speed': normalizedSpeed,
        }),
        options: Options(
          responseType: ResponseType.bytes,
          headers: _headers(apiKey, accept: 'audio/mpeg'),
        ),
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (received > _maxAudioBytes) {
            cancelToken?.cancel(ttsSizeLimitCancelReason);
          }
        },
      );
      final bytes = response.data ?? const <int>[];
      if (bytes.isEmpty) throw const FormatException('TTS 接口返回了空音频。');
      if (bytes.length > _maxAudioBytes) {
        throw const FormatException('TTS 音频超过 25 MB 限制。');
      }
      return SynthesizedSpeech(
        bytes: Uint8List.fromList(bytes),
        fileExtension: 'mp3',
        mimeType: 'audio/mpeg',
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw await _humanizeError(e, '语音生成');
    }
  }

  /// Alibaba Model Studio non-real-time TTS.
  ///
  /// Qwen3-TTS uses DashScope's multimodal-generation endpoint. The newer
  /// Qwen-Audio-TTS and CosyVoice families use the workspace-scoped
  /// SpeechSynthesizer endpoint. Both return a short-lived audio URL in
  /// `output.audio.url`, which is downloaded before this method returns so
  /// playback never depends on an expiring URL.
  Future<SynthesizedSpeech> _synthesizeAliyunSpeech({
    required MediaApiConfig config,
    required String apiKey,
    required String text,
    double? speed,
    CancelToken? cancelToken,
  }) async {
    final model = config.model.trim();
    final voice = config.voice.trim().isEmpty
        ? config.aliyunDefaultVoice
        : config.voice.trim();
    var instruction = config.voiceDesignPrompt.trim();
    final normalizedSpeed = speed?.clamp(0.5, 2.0).toDouble() ?? 1.0;
    if (instruction.isEmpty && normalizedSpeed != 1.0) {
      instruction = normalizedSpeed < 0.9 ? '语速稍慢，从容自然。' : '语速稍快，清晰利落。';
    }

    late final String endpoint;
    late final Map<String, dynamic> input;
    if (config.isAliyunQwen3TtsModel) {
      if (voice.isEmpty) {
        throw const FormatException('请为 Qwen3-TTS 选择一个系统音色。');
      }
      endpoint = _endpoint(
        config.baseUrl,
        'services/aigc/multimodal-generation/generation',
      );
      final supportsInstructions = model.toLowerCase().contains('instruct');
      input = {
        'text': text.trim(),
        'voice': voice,
        'language_type': _aliyunLanguageType(text),
        if (supportsInstructions && instruction.isNotEmpty)
          'instructions': instruction,
        if (supportsInstructions && instruction.isNotEmpty)
          'optimize_instructions': true,
      };
    } else if (config.isAliyunQwenAudioTtsModel ||
        config.isAliyunCosyVoiceTtsModel) {
      if (!config.hasAliyunWorkspaceBaseUrl) {
        throw const FormatException(
          'Qwen-Audio/CosyVoice 需要百炼 Workspace Base URL：'
          'https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1',
        );
      }
      if (voice.isEmpty) {
        throw FormatException(
          config.isAliyunCosyVoiceTtsModel
              ? 'CosyVoice v3.5 没有系统音色，请填写在百炼创建的复刻/设计 Voice ID。'
              : '请为 Qwen-Audio-TTS 选择或填写 Voice ID。',
        );
      }
      endpoint = _endpoint(
        config.baseUrl,
        'services/audio/tts/SpeechSynthesizer',
      );
      if (config.isAliyunCosyVoiceTtsModel && instruction.isNotEmpty) {
        instruction = _truncateAliyunInstruction(instruction, 100);
      }
      input = {
        'text': text.trim(),
        'voice': voice,
        'format': 'mp3',
        'sample_rate': 24000,
        'rate': normalizedSpeed,
        if (instruction.isNotEmpty) 'instruction': instruction,
      };
    } else {
      throw FormatException('暂不支持该百炼 TTS 模型：$model');
    }

    final response = await _postJson(
      endpoint,
      apiKey: apiKey,
      body: {'model': model, 'input': input},
      cancelToken: cancelToken,
      action: '百炼语音合成',
    );
    final statusCode = response['status_code'];
    if (statusCode is num && statusCode.toInt() != 200) {
      final detail = response['message']?.toString().trim();
      throw FormatException(
        detail == null || detail.isEmpty
            ? '百炼语音合成失败（${statusCode.toInt()}）。'
            : '百炼语音合成失败：$detail',
      );
    }

    final output = response['output'];
    final audio = output is Map ? output['audio'] : null;
    if (audio is! Map) {
      throw const FormatException('百炼语音合成接口没有返回音频数据。');
    }

    final rawUrl = audio['url'];
    if (rawUrl is String && rawUrl.trim().isNotEmpty) {
      return _downloadSynthesizedSpeech(
        rawUrl.trim(),
        cancelToken: cancelToken,
        fallbackExtension: config.isAliyunQwen3TtsModel ? 'wav' : 'mp3',
      );
    }

    final rawData = audio['data'];
    if (rawData is String && rawData.trim().isNotEmpty) {
      final extension = config.isAliyunQwen3TtsModel ? 'wav' : 'mp3';
      return SynthesizedSpeech(
        bytes: _decodeBase64Audio(rawData, '百炼语音合成'),
        fileExtension: extension,
        mimeType: extension == 'wav' ? 'audio/wav' : 'audio/mpeg',
      );
    }
    throw const FormatException('百炼语音合成接口返回了空音频。');
  }

  Future<SynthesizedSpeech> _downloadSynthesizedSpeech(
    String rawUrl, {
    CancelToken? cancelToken,
    required String fallbackExtension,
  }) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const FormatException('百炼语音合成接口返回了无效的音频地址。');
    }
    try {
      final response = await _dio.get<List<int>>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 400,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (received > _maxAudioBytes) {
            cancelToken?.cancel(ttsSizeLimitCancelReason);
          }
        },
      );
      final bytes = response.data ?? const <int>[];
      if (bytes.isEmpty) {
        throw const FormatException('百炼生成成功，但下载到的音频为空。');
      }
      if (bytes.length > _maxAudioBytes) {
        throw const FormatException('TTS 音频超过 25 MB 限制。');
      }
      final contentType = response.headers.value(Headers.contentTypeHeader);
      final format = _speechFormat(
        uri: uri,
        contentType: contentType,
        bytes: bytes,
        fallbackExtension: fallbackExtension,
      );
      return SynthesizedSpeech(
        bytes: Uint8List.fromList(bytes),
        fileExtension: format.$1,
        mimeType: format.$2,
      );
    } on FormatException {
      rethrow;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw await _humanizeError(e, '百炼音频下载');
    }
  }

  (String, String) _speechFormat({
    required Uri uri,
    required String? contentType,
    required List<int> bytes,
    required String fallbackExtension,
  }) {
    final mime = contentType?.split(';').first.trim().toLowerCase();
    if (mime == 'audio/wav' || mime == 'audio/x-wav') {
      return ('wav', 'audio/wav');
    }
    if (mime == 'audio/ogg' || mime == 'audio/opus') {
      return ('opus', 'audio/opus');
    }
    if (mime == 'audio/mpeg' || mime == 'audio/mp3') {
      return ('mp3', 'audio/mpeg');
    }
    final path = uri.path.toLowerCase();
    if (path.endsWith('.wav') ||
        (bytes.length >= 4 &&
            bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46)) {
      return ('wav', 'audio/wav');
    }
    if (path.endsWith('.opus') || path.endsWith('.ogg')) {
      return ('opus', 'audio/opus');
    }
    final fallback = fallbackExtension == 'wav' ? 'wav' : 'mp3';
    return fallback == 'wav' ? ('wav', 'audio/wav') : ('mp3', 'audio/mpeg');
  }

  String _aliyunLanguageType(String text) {
    final hasChinese = RegExp(r'[\u3400-\u9fff]').hasMatch(text);
    final hasLatin = RegExp(r'[A-Za-z]').hasMatch(text);
    if (hasChinese && hasLatin) return 'Auto';
    if (hasChinese) return 'Chinese';
    if (hasLatin) return 'English';
    return 'Auto';
  }

  /// CosyVoice instructions are limited to 100 weighted characters: CJK
  /// ideographs count as two, all other code points as one.
  String _truncateAliyunInstruction(String input, int maxWeight) {
    final buffer = StringBuffer();
    var weight = 0;
    for (final grapheme in input.characters) {
      final codePoint = grapheme.runes.first;
      final nextWeight = codePoint >= 0x3400 && codePoint <= 0x9FFF ? 2 : 1;
      if (weight + nextWeight > maxWeight) break;
      buffer.write(grapheme);
      weight += nextWeight;
    }
    return buffer.toString().trim();
  }

  Future<SynthesizedSpeech> _synthesizeMimoSpeech({
    required MediaApiConfig config,
    required String apiKey,
    required String text,
    double? speed,
    CancelToken? cancelToken,
    Uint8List? voiceSampleBytes,
    String voiceSampleMimeType = 'audio/wav',
  }) async {
    // Official MiMo V2.5 TTS series:
    // https://mimo.mi.com/docs/en-US/quick-start/usage-guide/audio/speech-synthesis-v2.5
    // - builtin (`mimo-v2.5-tts`): audio.voice = preset id
    // - design (`…-voicedesign`): user content = voice description (required)
    // - clone (`…-voiceclone`): audio.voice = data:{mime};base64,…
    final mode = config.mimoTtsMode;
    final designPrompt = config.voiceDesignPrompt.trim();
    final userContent = switch (mode) {
      MimoTtsMode.design => () {
        if (designPrompt.isEmpty) {
          throw const FormatException('请先在设置 → 能力 → 云端语音合成中填写「音色描述」。');
        }
        return designPrompt;
      }(),
      MimoTtsMode.builtin || MimoTtsMode.clone =>
        designPrompt.isNotEmpty ? designPrompt : _mimoTtsInstruction(speed),
    };

    final audio = <String, dynamic>{'format': 'wav'};
    switch (mode) {
      case MimoTtsMode.builtin:
        final voice = config.voice.trim();
        audio['voice'] = voice.isEmpty
            ? MediaApiConfig.mimoDefaultVoice
            : voice;
      case MimoTtsMode.design:
        // No preset voice; description already sits in the user message.
        // Keep optimize_text_preview off so assistant text is spoken as-is.
        audio['optimize_text_preview'] = false;
      case MimoTtsMode.clone:
        audio['voice'] = _mimoCloneVoiceDataUri(
          config: config,
          voiceSampleBytes: voiceSampleBytes,
          voiceSampleMimeType: voiceSampleMimeType,
        );
    }

    final response = await _postJson(
      _endpoint(config.baseUrl, 'chat/completions'),
      apiKey: apiKey,
      body: {
        'model': config.model.trim().isEmpty
            ? MediaApiConfig.modelForMimoTtsMode(mode, config.model)
            : config.model.trim(),
        'messages': [
          {'role': 'user', 'content': userContent},
          {'role': 'assistant', 'content': text.trim()},
        ],
        'audio': audio,
      },
      cancelToken: cancelToken,
      action: '语音合成',
    );
    final message = _firstChatMessage(response, '语音合成');
    final resultAudio = message['audio'];
    if (resultAudio is! Map) {
      throw const FormatException('语音合成接口没有返回音频数据。');
    }
    final rawData = resultAudio['data'];
    if (rawData is! String || rawData.trim().isEmpty) {
      throw const FormatException('语音合成接口没有返回音频数据。');
    }
    return SynthesizedSpeech(
      bytes: _decodeBase64Audio(rawData, '语音合成'),
      fileExtension: 'wav',
      mimeType: 'audio/wav',
    );
  }

  /// Builds the `audio.voice` data URI for voice cloning.
  ///
  /// Official limit: Base64 payload must stay under 10 MB; only mp3/wav.
  String _mimoCloneVoiceDataUri({
    required MediaApiConfig config,
    Uint8List? voiceSampleBytes,
    String voiceSampleMimeType = 'audio/wav',
  }) {
    final existing = config.voice.trim();
    if (existing.startsWith('data:')) return existing;

    final bytes = voiceSampleBytes;
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('请先在设置 → 能力 → 云端语音合成中上传用户音色样本（mp3/wav）。');
    }
    // 10 MB base64 ≈ 7.5 MB raw; keep a hard raw cap of 7 MB for safety.
    const maxRawBytes = 7 * 1024 * 1024;
    if (bytes.length > maxRawBytes) {
      throw const FormatException('用户音色样本过大，请使用不超过约 7 MB 的 mp3/wav。');
    }
    final mime = _audioMimeType(voiceSampleMimeType);
    if (mime != 'audio/wav' && mime != 'audio/mpeg' && mime != 'audio/mp3') {
      throw const FormatException('用户音色仅支持 mp3 或 wav 样本。');
    }
    final normalizedMime = mime == 'audio/mp3' ? 'audio/mpeg' : mime;
    return 'data:$normalizedMime;base64,${base64Encode(bytes)}';
  }

  /// Sends a recorded WAV (or another supported audio MIME type) to MiMo ASR
  /// and returns the transcript contained in `choices[0].message.content`.
  Future<String> transcribeMimoSpeech({
    required MediaApiConfig config,
    required String apiKey,
    required Uint8List audioBytes,
    required String mimeType,
    String language = 'auto',
    CancelToken? cancelToken,
  }) async {
    _ensureConfigured(config, apiKey, '语音识别');
    if (audioBytes.isEmpty) {
      throw const FormatException('录音为空，请重新录制。');
    }
    if (audioBytes.length > _maxAudioBytes) {
      throw const FormatException('录音超过 25 MB 限制。');
    }
    final normalizedMime = _audioMimeType(mimeType);
    final normalizedLanguage = language.trim().isEmpty
        ? 'auto'
        : language.trim();
    final response = await _postJson(
      _endpoint(config.baseUrl, 'chat/completions'),
      apiKey: apiKey,
      body: {
        'model': config.model.trim(),
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'input_audio',
                'input_audio': {
                  'data':
                      'data:$normalizedMime;base64,${base64Encode(audioBytes)}',
                },
              },
            ],
          },
        ],
        'asr_options': {'language': normalizedLanguage},
      },
      cancelToken: cancelToken,
      action: '语音识别',
    );
    final content = _firstChatMessage(response, '语音识别')['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const FormatException('语音识别接口没有返回文字结果。');
    }
    return content.trim();
  }

  /// Default style instruction when the user left [MediaApiConfig.voiceDesignPrompt]
  /// empty on builtin/clone models. Pace is derived from the UI rate slider.
  /// Fallback style when auto-emotion is off and the user left no prompt.
  /// Still asks for warmth so plain builtin TTS is less "播音腔".
  String _mimoTtsInstruction(double? speed) {
    final normalized = speed?.clamp(0.25, 4.0).toDouble() ?? 1;
    final pace = normalized < 0.9
        ? '语速稍慢，从容'
        : normalized > 1.1
        ? '语速稍快，利落'
        : '语速自然，有呼吸感';
    return '请用富有感情、生动自然的普通话朗读下面内容，'
        '像在对朋友说话而不是念稿，$pace。'
        '在标点处自然停顿，关键词可轻微加重，避免机械播音腔。';
  }

  Map<String, dynamic> _firstChatMessage(
    Map<String, dynamic> response,
    String action,
  ) {
    final choices = response['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw FormatException('$action接口没有返回有效结果。');
    }
    final message = (choices.first as Map)['message'];
    if (message is! Map) {
      throw FormatException('$action接口没有返回有效结果。');
    }
    return Map<String, dynamic>.from(message);
  }

  Uint8List _decodeBase64Audio(String raw, String action) {
    var payload = raw.trim();
    if (payload.startsWith('data:')) {
      final comma = payload.indexOf(',');
      if (comma < 0) {
        throw FormatException('$action接口返回了无效的音频数据。');
      }
      payload = payload.substring(comma + 1);
    }
    if (payload.length > _maxBase64Chars) {
      throw FormatException('$action音频超过 25 MB 限制。');
    }
    final normalized = _normalizeBase64(payload);
    if (normalized == null) {
      throw FormatException('$action接口返回了无效的 Base64 音频。');
    }
    final pad = (4 - normalized.length % 4) % 4;
    final padded = pad == 0
        ? normalized
        : normalized.padRight(normalized.length + pad, '=');
    try {
      final bytes = Uint8List.fromList(base64Decode(padded));
      if (bytes.isEmpty || bytes.length > _maxAudioBytes) {
        throw FormatException('$action音频为空或超过 25 MB 限制。');
      }
      return bytes;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw FormatException('$action接口返回了无效的 Base64 音频。');
    }
  }

  String _audioMimeType(String raw) {
    final mime = raw.trim().toLowerCase();
    if (RegExp(r'^audio/[a-z0-9.+-]+$').hasMatch(mime)) return mime;
    return 'audio/wav';
  }

  Future<Map<String, dynamic>> _postJson(
    String url, {
    required String apiKey,
    required Map<String, dynamic> body,
    CancelToken? cancelToken,
    String action = '请求',
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        url,
        data: jsonEncode(body),
        options: Options(headers: _headers(apiKey)),
        cancelToken: cancelToken,
      );
      final raw = response.data;
      if (raw is Map) return Map<String, dynamic>.from(raw);
      if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
      throw const FormatException('接口返回了无法识别的数据格式。');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw await _humanizeError(e, action);
    }
  }

  Map<String, String> _headers(
    String apiKey, {
    String accept = 'application/json',
  }) => {
    'Authorization': 'Bearer ${apiKey.trim()}',
    'Content-Type': 'application/json',
    'Accept': accept,
  };

  String _endpoint(String baseUrl, String path) {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/$path')) return base;
    return '$base/$path';
  }

  void _ensureConfigured(
    MediaApiConfig config,
    String apiKey,
    String capability,
  ) {
    if (!config.isConfiguredWith(apiKey)) {
      // Not a StateError: an unfilled API key is a user condition, not a
      // programming bug, and StateError.toString() would prefix "Bad state: ".
      throw Exception('$capability API 尚未完整配置。');
    }
    final uri = Uri.tryParse(config.baseUrl.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw FormatException('$capability Base URL 无效。');
    }
  }

  (String, String) _parseBase64Image(String raw) {
    var mimeType = 'image/png';
    var payload = raw.trim();
    if (payload.startsWith('data:')) {
      final comma = payload.indexOf(',');
      final header = comma < 0 ? '' : payload.substring(5, comma);
      // Accept both ";base64" and bare data URLs some gateways emit.
      if (comma < 0) {
        throw const FormatException('生图接口返回了无效的 data URL。');
      }
      final candidate = header.split(';').first;
      if (candidate.startsWith('image/')) mimeType = candidate;
      payload = payload.substring(comma + 1);
    }
    if (payload.length > _maxBase64Chars) {
      throw const FormatException('生成图片超过 24 MB 限制。');
    }
    // Clean + validate in one linear scan (see [_normalizeBase64]) instead of
    // a full decode: decoding up to 32M chars would allocate ~24 MB on the
    // caller's isolate only to be discarded.
    final normalized = _normalizeBase64(payload);
    if (normalized == null) {
      throw const FormatException('生图接口返回了无效的 Base64 图片。');
    }
    final pad = (4 - normalized.length % 4) % 4;
    final padded = pad == 0
        ? normalized
        : normalized.padRight(normalized.length + pad, '=');
    return (mimeType, padded);
  }

  /// Strip whitespace, map the URL-safe alphabet to the standard one and
  /// validate the payload in a single O(n) pass. Returns the unpadded payload,
  /// or null when it is not base64 at all.
  ///
  /// Deliberately hand-rolled rather than `RegExp(r'^[A-Za-z0-9+/]+={0,2}$')`:
  /// an anchored greedy loop keeps per-character backtrack state, and measured
  /// on this SDK it blows the regexp backtrack stack at exactly 4 MiB of base64
  /// - i.e. any generated image over 3 MiB, which most 1024px+ PNGs are. The
  /// resulting StackOverflowError reached the chat error banner as the bare
  /// text "Stack Overflow" and made img2img - which almost always comes back as
  /// `b64_json` rather than a URL - fail every single time.
  static String? _normalizeBase64(String payload) {
    if (payload.isEmpty) return null;
    var padding = 0; // trailing '=' count
    var stripped = 0; // whitespace dropped
    var rewritten = 0; // '-' / '_' mapped to '+' / '/'
    for (var i = 0; i < payload.length; i++) {
      final c = payload.codeUnitAt(i);
      // Standard alphabet: A-Z a-z 0-9 + /
      if ((c >= 0x41 && c <= 0x5A) ||
          (c >= 0x61 && c <= 0x7A) ||
          (c >= 0x30 && c <= 0x39) ||
          c == 0x2B ||
          c == 0x2F) {
        if (padding > 0) return null; // data after padding
        continue;
      }
      if (c == 0x3D) {
        // '=' — only ever 1-2 of them, at the very end.
        if (++padding > 2) return null;
        continue;
      }
      if (c == 0x2D || c == 0x5F) {
        // URL-safe '-' / '_'; base64Decode only accepts the standard alphabet.
        if (padding > 0) return null;
        rewritten++;
        continue;
      }
      if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
        // Gateways wrap long payloads at 64/76 columns.
        stripped++;
        continue;
      }
      return null;
    }
    final length = payload.length - padding - stripped;
    // A base64 quantum is 2-4 chars; a remainder of 1 can never be valid.
    if (length == 0 || length % 4 == 1) return null;
    if (stripped == 0 && rewritten == 0) {
      return padding == 0 ? payload : payload.substring(0, length);
    }
    // Slow path only when the gateway wrapped or URL-encoded the payload.
    final out = Uint8List(length);
    var n = 0;
    for (var i = 0; i < payload.length; i++) {
      final c = payload.codeUnitAt(i);
      if (c == 0x3D || c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
        continue;
      }
      out[n++] = c == 0x2D
          ? 0x2B
          : c == 0x5F
          ? 0x2F
          : c;
    }
    return String.fromCharCodes(out);
  }

  Future<Exception> _humanizeError(DioException e, String action) async {
    final status = e.response?.statusCode;
    final detail = _errorMessage(e.response?.data);
    final suffix = detail == null ? '' : '：$detail';
    if (status == 401) return Exception('$action鉴权失败（401）：请检查 API Key。');
    if (status == 404) {
      return Exception('$action接口未找到（404）：请检查 Base URL。$suffix');
    }
    if (status == 429) return Exception('$action请求过于频繁（429），请稍后重试。');
    if (status != null) return Exception('$action失败（$status）$suffix');
    if (e.type == DioExceptionType.connectionTimeout) {
      return Exception('$action连接超时：请检查网络或 Base URL。');
    }
    return Exception('$action失败：${e.message ?? e.type.name}');
  }

  String? _errorMessage(dynamic raw) {
    try {
      if (raw is String) raw = jsonDecode(raw);
      // /audio/speech is fetched with ResponseType.bytes, so a non-2xx error
      // body arrives as raw UTF-8 bytes instead of a decoded map.
      if (raw is List<int>) raw = jsonDecode(utf8.decode(raw));
      if (raw is! Map) return null;
      final error = raw['error'];
      final value = error is Map
          ? error['message'] ?? error['detail']
          : error ?? raw['message'];
      if (value is! String || value.trim().isEmpty) return null;
      final trimmed = value.trim();
      // Grapheme-aware cut so we can't split an emoji/surrogate pair.
      return trimmed.characters.length > 200
          ? '${trimmed.characters.take(200)}…'
          : trimmed;
    } catch (_) {
      return null;
    }
  }
}
