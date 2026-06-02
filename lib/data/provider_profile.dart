import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// A named, switchable LLM endpoint configuration. The app keeps a list of
/// these and one is "active" at a time (M3). The API key is stored separately
/// in secure storage keyed by [id]; it is NOT serialized into the profile JSON.
class ProviderProfile {
  ProviderProfile({
    String? id,
    required this.name,
    required this.baseUrl,
    required this.chatModel,
    required this.reasonerModel,
    List<String>? models,
  })  : id = id ?? _uuid.v4(),
        models = models ?? const [];

  final String id;

  /// User-facing label, e.g. "DeepSeek" or "My OpenAI".
  final String name;

  /// Base URL without the `/chat/completions` suffix.
  final String baseUrl;

  /// Default model used for normal chat.
  final String chatModel;

  /// Model used when "深度思考" is on. May equal [chatModel] for providers
  /// that have no dedicated reasoner.
  final String reasonerModel;

  /// All selectable model ids for this provider (for the model dropdown).
  final List<String> models;

  ProviderProfile copyWith({
    String? name,
    String? baseUrl,
    String? chatModel,
    String? reasonerModel,
    List<String>? models,
  }) =>
      ProviderProfile(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        chatModel: chatModel ?? this.chatModel,
        reasonerModel: reasonerModel ?? this.reasonerModel,
        models: models ?? this.models,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'chatModel': chatModel,
        'reasonerModel': reasonerModel,
        'models': models,
      };

  factory ProviderProfile.fromJson(Map<String, dynamic> json) =>
      ProviderProfile(
        id: json['id'] as String?,
        name: json['name'] as String? ?? '未命名',
        baseUrl: json['baseUrl'] as String? ?? '',
        chatModel: json['chatModel'] as String? ?? '',
        reasonerModel: json['reasonerModel'] as String? ??
            json['chatModel'] as String? ??
            '',
        models: (json['models'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// Built-in provider presets that one-click fill the base URL + model list.
/// Users still supply their own API key. Sourced from each provider's
/// OpenAI-compatible endpoint docs.
class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.baseUrl,
    required this.chatModel,
    required this.reasonerModel,
    required this.models,
  });

  final String name;
  final String baseUrl;
  final String chatModel;
  final String reasonerModel;
  final List<String> models;

  ProviderProfile toProfile() => ProviderProfile(
        name: name,
        baseUrl: baseUrl,
        chatModel: chatModel,
        reasonerModel: reasonerModel,
        models: models,
      );

  static const presets = <ProviderPreset>[
    ProviderPreset(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      chatModel: 'deepseek-v4-flash',
      reasonerModel: 'deepseek-v4-pro',
      models: ['deepseek-v4-flash', 'deepseek-v4-pro'],
    ),
    ProviderPreset(
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      chatModel: 'gpt-4o',
      reasonerModel: 'o3-mini',
      models: ['gpt-4o', 'gpt-4o-mini', 'o3-mini', 'o1'],
    ),
    ProviderPreset(
      name: 'Kimi (Moonshot)',
      baseUrl: 'https://api.moonshot.cn/v1',
      chatModel: 'moonshot-v1-8k',
      reasonerModel: 'kimi-thinking-preview',
      models: [
        'moonshot-v1-8k',
        'moonshot-v1-32k',
        'moonshot-v1-128k',
        'kimi-thinking-preview',
      ],
    ),
    ProviderPreset(
      name: '智谱 GLM',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      chatModel: 'glm-4-plus',
      reasonerModel: 'glm-zero-preview',
      models: ['glm-4-plus', 'glm-4-air', 'glm-zero-preview'],
    ),
  ];
}
