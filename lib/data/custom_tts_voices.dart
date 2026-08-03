import 'media_api_config.dart';

/// App-bundled "自制音色" packs.
///
/// These are **anime-style archetypes** expressed as MiMo voice-design
/// prompts (and optional local clone samples), not rips of copyrighted
/// character lines. That keeps the feature legal while still giving a strong
/// 二次元 flavour.
class CustomTtsVoicePack {
  const CustomTtsVoicePack({
    required this.id,
    required this.name,
    required this.tagline,
    required this.designPrompt,
    this.sampleAssetPath,
    this.sampleFileName,
    this.builtinVoiceFallback = MediaApiConfig.mimoDefaultVoice,
  });

  final String id;
  final String name;
  final String tagline;

  /// Primary path: `mimo-v2.5-tts-voicedesign` user-role description.
  final String designPrompt;

  /// Optional bundled sample under `assets/tts_voices/` for clone mode.
  final String? sampleAssetPath;

  /// Suggested filename when the sample is copied into app support.
  final String? sampleFileName;

  /// Fallback builtin voice if the user stays on `mimo-v2.5-tts`.
  final String builtinVoiceFallback;

  bool get hasCloneSample =>
      sampleAssetPath != null && sampleAssetPath!.trim().isNotEmpty;

  /// Applies this pack onto an existing TTS endpoint config (keeps URL/key).
  MediaApiConfig applyTo(
    MediaApiConfig current, {
    required CustomTtsVoiceApplyMode mode,
    String voiceClonePath = '',
  }) {
    final base = current.copyWith(
      speechProtocol: SpeechApiProtocol.mimoChatCompletions,
      baseUrl: current.baseUrl.trim().isEmpty
          ? MediaApiConfig.mimoBaseUrl
          : current.baseUrl,
    );
    return switch (mode) {
      CustomTtsVoiceApplyMode.design => base.copyWith(
        model: MediaApiConfig.mimoTtsDesignModel,
        voiceDesignPrompt: designPrompt,
        voice: '',
        voiceClonePath: '',
      ),
      CustomTtsVoiceApplyMode.clone => base.copyWith(
        model: MediaApiConfig.mimoTtsCloneModel,
        voiceDesignPrompt: '用自然、有感情的方式朗读，贴合角色气质：$tagline',
        voice: '',
        voiceClonePath: voiceClonePath,
      ),
      CustomTtsVoiceApplyMode.builtinStyle => base.copyWith(
        model: MediaApiConfig.mimoTtsModel,
        voice: builtinVoiceFallback,
        voiceDesignPrompt: designPrompt,
        voiceClonePath: '',
      ),
    };
  }
}

enum CustomTtsVoiceApplyMode {
  /// Recommended: MiMo voice design from the written persona.
  design,

  /// Uses a local sample file with `mimo-v2.5-tts-voiceclone`.
  clone,

  /// Keeps builtin voices but injects the persona as a style instruction.
  builtinStyle,
}

/// Curated anime-flavoured voice packs shipped with the app.
const List<CustomTtsVoicePack> kAnimeStyleVoicePacks = [
  CustomTtsVoicePack(
    id: 'genki_girl',
    name: '元气少女',
    tagline: '明亮跳脱 · 邻家高中生',
    builtinVoiceFallback: '茉莉',
    sampleAssetPath: 'assets/tts_voices/genki_girl.mp3',
    sampleFileName: 'genki_girl.mp3',
    designPrompt: '''
角色：十七岁元气满满的日系高中少女，短发利落，笑容很大，说话像夏日汽水。
音色：偏高亮、清晰、带一点鼻音甜感，中文普通话，节奏轻快有弹性。
气质：热情、正能量、偶尔会「诶嘿」地笑出声，但不做作。
演绎：句尾常微微上扬；感叹时更兴奋；安慰人时突然变温柔。
场景：给好朋友讲今天发生的趣事。
''',
  ),
  CustomTtsVoicePack(
    id: 'tsundere',
    name: '傲娇大小姐',
    tagline: '别误会 · 才不是关心你',
    builtinVoiceFallback: '冰糖',
    sampleAssetPath: 'assets/tts_voices/tsundere.mp3',
    sampleFileName: 'tsundere.mp3',
    designPrompt: '''
角色：十八岁高傲大小姐，家世优渥，嘴硬心软的经典傲娇。
音色：中高女声，咬字清楚偏冷艳，但情绪一上来会破功变软。
气质：表面不耐烦、爱用「哼」「才不是」，内心其实在意对方。
演绎：否定句要短促；关心的话故意说得别扭；害羞时语速变快、音量略降。
场景：嘴上嫌弃却还是来帮忙的对话。
''',
  ),
  CustomTtsVoicePack(
    id: 'cool_boy',
    name: '清冷少年',
    tagline: '克制低沉 · 话少有分量',
    builtinVoiceFallback: '白桦',
    sampleAssetPath: 'assets/tts_voices/cool_boy.mp3',
    sampleFileName: 'cool_boy.mp3',
    designPrompt: '''
角色：二十岁清冷少年，黑发，眼神淡，习惯把情绪收在句子里。
音色：偏低的年轻男声，共鸣靠前但不沙哑，语速偏慢，停顿干净。
气质：克制、冷静、偶尔一句温柔会显得格外珍贵。
演绎：少用夸张起伏；关键词轻轻加重；长句中间留白，像在思考后才开口。
场景：夜色里简短却真诚的对话。
''',
  ),
  CustomTtsVoicePack(
    id: 'onee_san',
    name: '温柔御姐',
    tagline: '成熟柔声 · 安抚感',
    builtinVoiceFallback: '冰糖',
    sampleAssetPath: 'assets/tts_voices/onee_san.mp3',
    sampleFileName: 'onee_san.mp3',
    designPrompt: '''
角色：二十七岁成熟女性，知性温柔，像可靠的大姐姐。
音色：中低女声，圆润有磁性，气声适度，中文普通话自然流畅。
气质：包容、稳、带笑意，不娇气也不高高在上。
演绎：安抚时更慢更软；讲道理时条理清楚；偶尔轻笑一声再继续。
场景：在灯下安慰正在焦虑的人。
''',
  ),
  CustomTtsVoicePack(
    id: 'hotblood',
    name: '热血少年',
    tagline: '燃起来了 · 中气十足',
    builtinVoiceFallback: '苏打',
    sampleAssetPath: 'assets/tts_voices/hotblood.mp3',
    sampleFileName: 'hotblood.mp3',
    designPrompt: '''
角色：十六岁热血少年，嗓门大、眼神亮，相信努力能改变一切。
音色：偏高昂的年轻男声，中气足，咬字有力，语速偏快但不糊。
气质：冲动、真诚、鼓舞人心，像要拉着听众一起冲。
演绎：口号式句子加重；转折处换气明显；激动时音量上去，收尾仍干净。
场景：赛前鼓舞队友，或立下响亮的约定。
''',
  ),
  CustomTtsVoicePack(
    id: 'dandere',
    name: '软萌宅女',
    tagline: '小声试探 · 内向可爱',
    builtinVoiceFallback: '茉莉',
    sampleAssetPath: 'assets/tts_voices/dandere.mp3',
    sampleFileName: 'dandere.mp3',
    designPrompt: '''
角色：十九岁内向宅女，说话轻、容易紧张，熟悉后会变得话多。
音色：偏细的女声，音量不大，尾音软，偶尔吞吞吐吐。
气质：害羞、真诚、有点天然，笑声短而轻。
演绎：开场略犹豫；说到喜欢的事物突然流畅起来；句末可带一点点气声。
场景：第一次鼓起勇气分享自己喜欢的故事。
''',
  ),
];

CustomTtsVoicePack? customTtsVoicePackById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final pack in kAnimeStyleVoicePacks) {
    if (pack.id == id) return pack;
  }
  return null;
}
