/// Configuration shared by the optional vision, image-generation and speech
/// endpoints.
///
/// API keys deliberately do not live here because this object is serialized to
/// SharedPreferences. Keys are stored separately in the platform secure store.
class MediaApiConfig {
  const MediaApiConfig({
    this.baseUrl = '',
    this.model = '',
    this.voice = openAiDefaultVoice,
    this.voiceDesignPrompt = '',
    this.voiceClonePath = '',
    this.imageSize = '1024x1024',
    this.speechProtocol = SpeechApiProtocol.openAiAudio,
  });

  /// MiMo's documented API base and default speech model identifiers.
  /// See: https://mimo.mi.com/docs/en-US/quick-start/usage-guide/audio/speech-synthesis-v2.5
  static const mimoBaseUrl = 'https://api.xiaomimimo.com/v1';
  static const mimoAsrModel = 'mimo-v2.5-asr';
  static const mimoTtsModel = 'mimo-v2.5-tts';
  static const mimoTtsDesignModel = 'mimo-v2.5-tts-voicedesign';
  static const mimoTtsCloneModel = 'mimo-v2.5-tts-voiceclone';
  static const mimoDefaultVoice = 'mimo_default';

  /// Alibaba Cloud Model Studio (DashScope) speech defaults.
  ///
  /// Qwen3-TTS uses the public DashScope endpoint. Qwen-Audio-TTS and
  /// CosyVoice use the same protocol shape but require a workspace-scoped
  /// `https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1` base URL.
  static const aliyunModelStudioBaseUrl =
      'https://dashscope.aliyuncs.com/api/v1';
  static const aliyunQwen3TtsModel = 'qwen3-tts-instruct-flash';
  static const aliyunQwenAudioTtsModel = 'qwen-audio-3.0-tts-flash';
  static const aliyunCosyVoiceTtsModel = 'cosyvoice-v3.5-flash';
  static const aliyunQwen3DefaultVoice = 'Cherry';
  static const aliyunQwenAudioDefaultVoice = 'longanhuan_v3.6';

  /// The voice OpenAI-compatible gateways fall back to when none is sent.
  /// Deliberately not enforced anywhere (see [isConfiguredWith]).
  static const openAiDefaultVoice = 'alloy';

  /// Built-in MiMo voices for `mimo-v2.5-tts` (official docs, 2026-07).
  static const List<SpeechVoiceOption> mimoBuiltinVoices = [
    SpeechVoiceOption(
      id: mimoDefaultVoice,
      label: 'MiMo 默认',
      detail: '集群默认（国内≈冰糖）',
      language: '自动',
    ),
    SpeechVoiceOption(
      id: '冰糖',
      label: '冰糖',
      detail: '女声 · 中文',
      language: '中文',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: '茉莉',
      label: '茉莉',
      detail: '女声 · 中文',
      language: '中文',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: '苏打',
      label: '苏打',
      detail: '男声 · 中文',
      language: '中文',
      gender: '男',
    ),
    SpeechVoiceOption(
      id: '白桦',
      label: '白桦',
      detail: '男声 · 中文',
      language: '中文',
      gender: '男',
    ),
    SpeechVoiceOption(
      id: 'Mia',
      label: 'Mia',
      detail: 'Female · English',
      language: 'English',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: 'Chloe',
      label: 'Chloe',
      detail: 'Female · English',
      language: 'English',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: 'Milo',
      label: 'Milo',
      detail: 'Male · English',
      language: 'English',
      gender: '男',
    ),
    SpeechVoiceOption(
      id: 'Dean',
      label: 'Dean',
      detail: 'Male · English',
      language: 'English',
      gender: '男',
    ),
  ];

  /// Common OpenAI-compatible `/audio/speech` voices.
  static const List<SpeechVoiceOption> openAiBuiltinVoices = [
    SpeechVoiceOption(id: 'alloy', label: 'Alloy', detail: '中性'),
    SpeechVoiceOption(id: 'ash', label: 'Ash', detail: '沉稳'),
    SpeechVoiceOption(id: 'ballad', label: 'Ballad', detail: '叙事'),
    SpeechVoiceOption(id: 'coral', label: 'Coral', detail: '明亮'),
    SpeechVoiceOption(id: 'echo', label: 'Echo', detail: '男声'),
    SpeechVoiceOption(id: 'fable', label: 'Fable', detail: '英式'),
    SpeechVoiceOption(id: 'nova', label: 'Nova', detail: '女声'),
    SpeechVoiceOption(id: 'onyx', label: 'Onyx', detail: '低沉'),
    SpeechVoiceOption(id: 'sage', label: 'Sage', detail: '温和'),
    SpeechVoiceOption(id: 'shimmer', label: 'Shimmer', detail: '柔和'),
    SpeechVoiceOption(id: 'verse', label: 'Verse', detail: '表现力'),
  ];

  /// Curated system voices supported by Qwen3-TTS non-real-time synthesis.
  static const List<SpeechVoiceOption> aliyunQwen3BuiltinVoices = [
    SpeechVoiceOption(
      id: 'Cherry',
      label: '芊悦',
      detail: '阳光自然小姐姐',
      language: '中英等多语种',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: 'Serena',
      label: '苏瑶',
      detail: '温柔小姐姐',
      language: '中英等多语种',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: 'Ethan',
      label: '晨煦',
      detail: '阳光温暖男声',
      language: '中英等多语种',
      gender: '男',
    ),
    SpeechVoiceOption(
      id: 'Chelsie',
      label: '千雪',
      detail: '二次元虚拟女友',
      language: '中英等多语种',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: 'Momo',
      label: '茉兔',
      detail: '撒娇搞怪',
      language: '中英等多语种',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: 'Seren',
      label: '小婉',
      detail: '温和舒缓',
      language: '中英等多语种',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: 'Pip',
      label: '顽屁小孩',
      detail: '调皮童声',
      language: '中英等多语种',
      gender: '男',
    ),
  ];

  /// System voices currently exposed by Qwen-Audio 3.0 TTS Flash.
  static const List<SpeechVoiceOption> aliyunQwenAudioBuiltinVoices = [
    SpeechVoiceOption(
      id: aliyunQwenAudioDefaultVoice,
      label: '龙安欢',
      detail: '精品中文女声',
      language: '中文 / 英文',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: 'longjielidou_v3.6',
      label: '龙杰力豆',
      detail: '天真男童',
      language: '中文 / 英文',
      gender: '男',
    ),
    SpeechVoiceOption(
      id: 'loongeva_v3.6',
      label: 'Loongeva',
      detail: '高智感美式女声',
      language: '英文',
      gender: '女',
    ),
    SpeechVoiceOption(
      id: 'loongjohn',
      label: 'LoongJohn',
      detail: '沉稳美式男声',
      language: '英文',
      gender: '男',
    ),
  ];

  final String baseUrl;
  final String model;

  /// Used by the TTS endpoint.
  ///
  /// - Built-in / OpenAI: a voice id (`冰糖`, `alloy`, …)
  /// - Voice clone: may hold a `data:audio/...;base64,...` URI after load
  /// - Voice design: unused (description lives in [voiceDesignPrompt])
  final String voice;

  /// Natural-language voice/style control.
  ///
  /// - `mimo-v2.5-tts-voicedesign`: **required** voice description (user role)
  /// - other MiMo TTS models: optional style / director instruction
  final String voiceDesignPrompt;

  /// Absolute path to a local mp3/wav sample used by
  /// `mimo-v2.5-tts-voiceclone`. The raw audio is never written into
  /// SharedPreferences — only this path is persisted.
  final String voiceClonePath;

  /// Used only by the image-generation endpoint.
  final String imageSize;

  /// The wire protocol used by a text-to-speech endpoint.
  final SpeechApiProtocol speechProtocol;

  /// GPT Image models (`gpt-image-1`, `gpt-image-2`, …) accept multiple
  /// reference images on `/images/edits` via repeated `image[]` parts.
  /// Older single-image edits gateways stay at one reference.
  bool get supportsMultiReferenceImages =>
      supportsMultiReferenceImageModel(model);

  /// Max reference images for img2img this config may send.
  int get maxImageEditReferences =>
      supportsMultiReferenceImages ? maxGptImageEditReferences : 1;

  /// Upper bound for multi-ref GPT Image edits (`gpt-image-*` allows 16).
  static const maxGptImageEditReferences = 16;

  static bool supportsMultiReferenceImageModel(String model) {
    final m = model.toLowerCase().split('/').last;
    return m.contains('gpt-image');
  }

  /// Whether this endpoint can serve requests: a valid http(s) URL, a model
  /// id and a non-empty API key.
  ///
  /// `voice` is deliberately NOT part of the check: it is an optional field.
  /// OpenAI-compatible gateways fall back to [openAiDefaultVoice] and the
  /// MiMo path to [mimoDefaultVoice], so an endpoint remains usable without
  /// it — forcing a voice here would only confuse users who configured
  /// baseUrl/model/key but never touched the voice field.
  bool isConfiguredWith(String apiKey) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri != null &&
        uri.host.isNotEmpty &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        model.trim().isNotEmpty &&
        apiKey.trim().isNotEmpty;
  }

  /// True when [baseUrl] / [model] clearly point at Xiaomi MiMo speech APIs.
  ///
  /// Used to auto-select [SpeechApiProtocol.mimoChatCompletions]: MiMo TTS
  /// does not implement OpenAI `/audio/speech`, so leaving the default
  /// protocol after pasting a MiMo base URL is a common hard failure.
  bool get looksLikeMimoSpeechEndpoint =>
      looksLikeMimoSpeech(baseUrl: baseUrl, model: model);

  /// True when the endpoint/model clearly points at Alibaba Model Studio TTS.
  bool get looksLikeAliyunSpeechEndpoint =>
      looksLikeAliyunSpeech(baseUrl: baseUrl, model: model);

  /// Wire protocol that should actually be used for TTS requests.
  ///
  /// Prefer an automatic MiMo upgrade when the endpoint is unmistakably
  /// Xiaomi MiMo; otherwise keep the user-selected [speechProtocol].
  SpeechApiProtocol get effectiveSpeechProtocol {
    if (looksLikeMimoSpeechEndpoint) {
      return SpeechApiProtocol.mimoChatCompletions;
    }
    if (looksLikeAliyunSpeechEndpoint) {
      return SpeechApiProtocol.aliyunModelStudio;
    }
    return speechProtocol;
  }

  /// Which MiMo TTS capability the current [model] targets.
  MimoTtsMode get mimoTtsMode => MimoTtsMode.fromModel(model);

  /// Whether a local clone sample has been selected.
  bool get hasVoiceCloneSample => voiceClonePath.trim().isNotEmpty;

  /// Whether [baseUrl] / [model] identify a Xiaomi MiMo speech endpoint.
  static bool looksLikeMimoSpeech({
    required String baseUrl,
    required String model,
  }) {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
    if (host.contains('xiaomimimo') ||
        host == 'mimo.mi.com' ||
        host.endsWith('.mimo.mi.com')) {
      return true;
    }
    final normalizedModel = model.trim().toLowerCase();
    if (normalizedModel.isEmpty) return false;
    // mimo-v2.5-tts, mimo-v2.5-asr, mimo-v2.5-tts-voiceclone, …
    return normalizedModel.startsWith('mimo') &&
        (normalizedModel.contains('tts') || normalizedModel.contains('asr'));
  }

  /// Whether [baseUrl] / [model] identify Alibaba Model Studio speech.
  static bool looksLikeAliyunSpeech({
    required String baseUrl,
    required String model,
  }) {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
    final normalizedModel = model.trim().toLowerCase();
    final looksLikeTtsModel =
        normalizedModel.startsWith('qwen3-tts') ||
        normalizedModel.startsWith('qwen-audio-') &&
            normalizedModel.contains('-tts-') ||
        normalizedModel.startsWith('cosyvoice-');
    if (looksLikeTtsModel) return true;
    return host.endsWith('.maas.aliyuncs.com') &&
        normalizedModel.contains('tts');
  }

  bool get isAliyunQwen3TtsModel =>
      model.trim().toLowerCase().startsWith('qwen3-tts');

  bool get isAliyunQwenAudioTtsModel =>
      model.trim().toLowerCase().startsWith('qwen-audio-') &&
      model.trim().toLowerCase().contains('-tts-');

  bool get isAliyunCosyVoiceTtsModel =>
      model.trim().toLowerCase().startsWith('cosyvoice-');

  bool get hasAliyunWorkspaceBaseUrl {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
    return host.endsWith('.cn-beijing.maas.aliyuncs.com') &&
        host != 'cn-beijing.maas.aliyuncs.com';
  }

  List<SpeechVoiceOption> get aliyunBuiltinVoices {
    if (isAliyunQwen3TtsModel) return aliyunQwen3BuiltinVoices;
    if (isAliyunQwenAudioTtsModel) return aliyunQwenAudioBuiltinVoices;
    // CosyVoice v3.5 intentionally has no system voices: users must enter a
    // voice-cloning or voice-design id created in Model Studio.
    return const [];
  }

  String get aliyunDefaultVoice {
    if (isAliyunQwenAudioTtsModel) return aliyunQwenAudioDefaultVoice;
    if (isAliyunQwen3TtsModel) return aliyunQwen3DefaultVoice;
    return '';
  }

  /// Infers the TTS protocol for settings edits without downgrading a
  /// deliberate OpenAI choice on a non-MiMo host.
  static SpeechApiProtocol inferSpeechProtocol({
    required String baseUrl,
    required String model,
    required SpeechApiProtocol current,
  }) {
    if (looksLikeMimoSpeech(baseUrl: baseUrl, model: model)) {
      return SpeechApiProtocol.mimoChatCompletions;
    }
    if (looksLikeAliyunSpeech(baseUrl: baseUrl, model: model)) {
      return SpeechApiProtocol.aliyunModelStudio;
    }
    return current;
  }

  /// Model id that matches a chosen MiMo TTS mode while keeping a non-MiMo
  /// custom model untouched.
  static String modelForMimoTtsMode(MimoTtsMode mode, String currentModel) {
    final normalized = currentModel.trim().toLowerCase();
    final looksMimoTts =
        normalized.startsWith('mimo') && normalized.contains('tts');
    if (!looksMimoTts && normalized.isNotEmpty) {
      // User is on a custom gateway model id — only swap when already MiMo.
      return currentModel;
    }
    return switch (mode) {
      MimoTtsMode.builtin => mimoTtsModel,
      MimoTtsMode.design => mimoTtsDesignModel,
      MimoTtsMode.clone => mimoTtsCloneModel,
    };
  }

  MediaApiConfig copyWith({
    String? baseUrl,
    String? model,
    String? voice,
    String? voiceDesignPrompt,
    String? voiceClonePath,
    String? imageSize,
    SpeechApiProtocol? speechProtocol,
  }) => MediaApiConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    voice: voice ?? this.voice,
    voiceDesignPrompt: voiceDesignPrompt ?? this.voiceDesignPrompt,
    voiceClonePath: voiceClonePath ?? this.voiceClonePath,
    imageSize: imageSize ?? this.imageSize,
    speechProtocol: speechProtocol ?? this.speechProtocol,
  );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'model': model,
    'voice': voice,
    'voiceDesignPrompt': voiceDesignPrompt,
    'voiceClonePath': voiceClonePath,
    'imageSize': imageSize,
    'speechProtocol': speechProtocol.name,
  };

  factory MediaApiConfig.fromJson(Map<String, dynamic> json) => MediaApiConfig(
    baseUrl: json['baseUrl'] as String? ?? '',
    model: json['model'] as String? ?? '',
    voice: json['voice'] as String? ?? openAiDefaultVoice,
    voiceDesignPrompt: json['voiceDesignPrompt'] as String? ?? '',
    voiceClonePath: json['voiceClonePath'] as String? ?? '',
    imageSize: json['imageSize'] as String? ?? '1024x1024',
    speechProtocol: SpeechApiProtocol.fromWire(
      json['speechProtocol'] as String?,
    ),
  );
}

/// A selectable TTS voice shown in settings.
class SpeechVoiceOption {
  const SpeechVoiceOption({
    required this.id,
    required this.label,
    this.detail = '',
    this.language = '',
    this.gender = '',
  });

  final String id;
  final String label;
  final String detail;
  final String language;
  final String gender;
}

/// MiMo V2.5 TTS series capabilities (one model per mode).
enum MimoTtsMode {
  /// `mimo-v2.5-tts` — built-in high-quality voices.
  builtin,

  /// `mimo-v2.5-tts-voicedesign` — free-text voice description.
  design,

  /// `mimo-v2.5-tts-voiceclone` — clone from a user audio sample.
  clone;

  static MimoTtsMode fromModel(String model) {
    final normalized = model.trim().toLowerCase();
    if (normalized.contains('voicedesign')) return MimoTtsMode.design;
    if (normalized.contains('voiceclone')) return MimoTtsMode.clone;
    return MimoTtsMode.builtin;
  }

  String get label => switch (this) {
    MimoTtsMode.builtin => '内置音色',
    MimoTtsMode.design => '文案设计',
    MimoTtsMode.clone => '用户音色',
  };

  String get description => switch (this) {
    MimoTtsMode.builtin => '官方预设音色，开箱即用',
    MimoTtsMode.design => '用自然语言描述想要的声音',
    MimoTtsMode.clone => '上传你的录音样本进行克隆',
  };
}

/// Supported TTS API wire formats.
enum SpeechApiProtocol {
  /// OpenAI-compatible `POST /audio/speech` returning audio bytes.
  openAiAudio,

  /// MiMo `POST /chat/completions` returning Base64 WAV in the JSON response.
  mimoChatCompletions,

  /// Alibaba Model Studio HTTP TTS returning an audio URL or Base64 payload.
  aliyunModelStudio;

  static SpeechApiProtocol fromWire(String? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return SpeechApiProtocol.openAiAudio;
  }
}

enum MediaApiKind { vision, imageGeneration, tts, asr }
