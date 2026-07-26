/// Configuration shared by the optional vision, image-generation and
/// text-to-speech endpoints.
///
/// API keys deliberately do not live here because this object is serialized to
/// SharedPreferences. Keys are stored separately in the platform secure store.
class MediaApiConfig {
  const MediaApiConfig({
    this.baseUrl = '',
    this.model = '',
    this.voice = 'alloy',
    this.imageSize = '1024x1024',
  });

  final String baseUrl;
  final String model;

  /// Used only by the TTS endpoint.
  final String voice;

  /// Used only by the image-generation endpoint.
  final String imageSize;

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
  }) => MediaApiConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    voice: voice ?? this.voice,
    imageSize: imageSize ?? this.imageSize,
  );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'model': model,
    'voice': voice,
    'imageSize': imageSize,
  };

  factory MediaApiConfig.fromJson(Map<String, dynamic> json) => MediaApiConfig(
    baseUrl: json['baseUrl'] as String? ?? '',
    model: json['model'] as String? ?? '',
    voice: json['voice'] as String? ?? 'alloy',
    imageSize: json['imageSize'] as String? ?? '1024x1024',
  );
}

enum MediaApiKind { vision, imageGeneration, tts }
