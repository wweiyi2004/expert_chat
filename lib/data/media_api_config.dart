/// Configuration shared by the optional vision, image-generation and speech
/// endpoints.
///
/// API keys deliberately do not live here because this object is serialized to
/// SharedPreferences. Keys are stored separately in the platform secure store.
class MediaApiConfig {
  const MediaApiConfig({
    this.baseUrl = '',
    this.model = '',
    this.voice = 'alloy',
    this.imageSize = '1024x1024',
    this.speechProtocol = SpeechApiProtocol.openAiAudio,
  });

  /// MiMo's documented API base and default speech model identifiers.
  static const mimoBaseUrl = 'https://api.xiaomimimo.com/v1';
  static const mimoAsrModel = 'mimo-v2.5-asr';
  static const mimoTtsModel = 'mimo-v2.5-tts';
  static const mimoDefaultVoice = 'mimo_default';

  final String baseUrl;
  final String model;

  /// Used only by the TTS endpoint.
  final String voice;

  /// Used only by the image-generation endpoint.
  final String imageSize;

  /// The wire protocol used by a text-to-speech endpoint.
  final SpeechApiProtocol speechProtocol;

  bool isConfiguredWith(String apiKey) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri != null &&
        uri.host.isNotEmpty &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        model.trim().isNotEmpty &&
        apiKey.trim().isNotEmpty;
  }

  MediaApiConfig copyWith({
    String? baseUrl,
    String? model,
    String? voice,
    String? imageSize,
    SpeechApiProtocol? speechProtocol,
  }) => MediaApiConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    voice: voice ?? this.voice,
    imageSize: imageSize ?? this.imageSize,
    speechProtocol: speechProtocol ?? this.speechProtocol,
  );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'model': model,
    'voice': voice,
    'imageSize': imageSize,
    'speechProtocol': speechProtocol.name,
  };

  factory MediaApiConfig.fromJson(Map<String, dynamic> json) => MediaApiConfig(
    baseUrl: json['baseUrl'] as String? ?? '',
    model: json['model'] as String? ?? '',
    voice: json['voice'] as String? ?? 'alloy',
    imageSize: json['imageSize'] as String? ?? '1024x1024',
    speechProtocol: SpeechApiProtocol.fromWire(
      json['speechProtocol'] as String?,
    ),
  );
}

/// Supported TTS API wire formats.
enum SpeechApiProtocol {
  /// OpenAI-compatible `POST /audio/speech` returning audio bytes.
  openAiAudio,

  /// MiMo `POST /chat/completions` returning Base64 WAV in the JSON response.
  mimoChatCompletions;

  static SpeechApiProtocol fromWire(String? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return SpeechApiProtocol.openAiAudio;
  }
}

enum MediaApiKind { vision, imageGeneration, tts, asr }
