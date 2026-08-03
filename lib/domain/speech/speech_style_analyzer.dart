import 'package:characters/characters.dart';

/// Infers a natural-language delivery instruction for one TTS chunk so MiMo
/// (and similar instruction-following TTS APIs) can sound more expressive.
///
/// The result is meant for the **user** role message: MiMo treats that field
/// as style / director guidance, while the spoken text stays in **assistant**.
///
/// Heuristics are deliberately lightweight (no network): punctuation, emoji,
/// dialogue markers and a small Chinese emotion lexicon.
String analyzeSpeechStyle(
  String rawText, {
  double? speed,
  String? baseVoiceHint,
}) {
  final text = rawText.trim();
  if (text.isEmpty) {
    return _composeInstruction(
      tone: '自然、清晰、有温度',
      pace: _paceLabel(speed),
      extras: const [],
      baseVoiceHint: baseVoiceHint,
    );
  }

  final scores = <_Emotion, int>{
    for (final e in _Emotion.values) e: 0,
  };

  void bump(_Emotion e, [int n = 1]) => scores[e] = (scores[e] ?? 0) + n;

  // Punctuation / intensity.
  final excl = RegExp(r'[!！]').allMatches(text).length;
  final quest = RegExp(r'[?？]').allMatches(text).length;
  final ellipsis = RegExp(r'[…～~]|\.\.\.').allMatches(text).length;
  final multiExcl = RegExp(r'[!！]{2,}').hasMatch(text);
  if (excl > 0) bump(_Emotion.excited, excl + (multiExcl ? 2 : 0));
  if (quest > 0) bump(_Emotion.curious, quest);
  if (ellipsis > 0) bump(_Emotion.gentle, ellipsis);

  // Dialogue / quote → more performative.
  final hasDialogue = text.contains('「') ||
      text.contains('」') ||
      text.contains('"') ||
      text.contains('"') ||
      text.contains('"');
  if (hasDialogue) bump(_Emotion.playful, 1);

  // Lexicon.
  for (final entry in _lexicon.entries) {
    for (final word in entry.value) {
      if (text.contains(word)) bump(entry.key, 2);
    }
  }

  // Emoji-ish markers often left in chat.
  if (RegExp(r'[😂🤣😆开心哈哈]').hasMatch(text)) bump(_Emotion.happy, 2);
  if (RegExp(r'[😢😭委屈呜]').hasMatch(text)) bump(_Emotion.sad, 2);
  if (RegExp(r'[😡💢生气]').hasMatch(text)) bump(_Emotion.angry, 2);
  if (RegExp(r'[❤️💕温柔]').hasMatch(text)) bump(_Emotion.tender, 2);

  // Length → narration vs punchy line.
  final len = text.characters.length;
  if (len > 80) bump(_Emotion.narrative, 1);
  if (len <= 12 && excl > 0) bump(_Emotion.excited, 1);

  // Pick top emotion; fall back to warm narrative.
  final ranked = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final top = ranked.first;
  final emotion = top.value > 0 ? top.key : _Emotion.warm;

  final secondary = ranked.length > 1 && ranked[1].value > 0
      ? ranked[1].key
      : null;

  return _composeInstruction(
    tone: emotion.tone,
    pace: emotion.paceOverride ?? _paceLabel(speed),
    extras: [
      emotion.direction,
      if (secondary != null && secondary != emotion) secondary.direction,
      if (hasDialogue) '对话部分更口语、有角色感，旁白稍稳',
      if (len > 120) '长句注意换气与停顿，避免一口气念完',
    ],
    baseVoiceHint: baseVoiceHint,
  );
}

/// Merges a fixed voice-design / user style prompt with a per-chunk emotion
/// instruction. Design mode needs the identity description first; emotion is
/// appended as performance direction for the current sentence.
String mergeSpeechStyleInstructions({
  required String? basePrompt,
  required String? autoStyle,
  required bool designMode,
}) {
  final base = basePrompt?.trim() ?? '';
  final auto = autoStyle?.trim() ?? '';
  if (base.isEmpty) return auto;
  if (auto.isEmpty) return base;
  if (designMode) {
    return '$base\n\n【本句情绪与演绎】\n$auto';
  }
  return '$base\n\n$auto';
}

String _paceLabel(double? speed) {
  final normalized = speed?.clamp(0.25, 4.0) ?? 1.0;
  if (normalized < 0.9) return '语速稍慢，从容';
  if (normalized > 1.1) return '语速稍快，利落';
  return '语速自然，有呼吸感';
}

String _composeInstruction({
  required String tone,
  required String pace,
  required List<String> extras,
  String? baseVoiceHint,
}) {
  final hint = baseVoiceHint?.trim();
  final parts = <String>[
    if (hint != null && hint.isNotEmpty) '保持既定音色与人设：$hint',
    '请用富有感情、生动自然的普通话朗读下面内容。',
    '整体气质：$tone。',
    '$pace。',
    '带一点真实的气息与语气起伏，避免机械播音腔；在标点处自然停顿，关键词可轻微加重。',
    for (final e in extras)
      if (e.trim().isNotEmpty) e.trim(),
  ];
  return parts.join('');
}

enum _Emotion {
  warm,
  happy,
  excited,
  tender,
  sad,
  angry,
  curious,
  playful,
  gentle,
  serious,
  narrative,
}

extension on _Emotion {
  String get tone => switch (this) {
    _Emotion.warm => '温暖亲切、像朋友聊天',
    _Emotion.happy => '轻快明亮、带着笑意',
    _Emotion.excited => '兴奋高昂、有感染力',
    _Emotion.tender => '柔和体贴、轻声细语',
    _Emotion.sad => '低回沉缓、略带感伤',
    _Emotion.angry => '短促有力、带着怒意但不嘶吼',
    _Emotion.curious => '探究疑惑、句尾微微上扬',
    _Emotion.playful => '俏皮活泼、有点小得意',
    _Emotion.gentle => '舒缓安静、若有所思',
    _Emotion.serious => '沉稳认真、条理清晰',
    _Emotion.narrative => '说书叙事、有画面感',
  };

  String get direction => switch (this) {
    _Emotion.warm => '嘴角带笑，尾音略柔',
    _Emotion.happy => '节奏轻快，可有浅浅的笑意',
    _Emotion.excited => '能量更高，感叹处加重',
    _Emotion.tender => '音量略低，咬字更软',
    _Emotion.sad => '气声稍多，句末下沉',
    _Emotion.angry => '字正腔圆，顿挫分明',
    _Emotion.curious => '疑问句尾上扬，停顿思考',
    _Emotion.playful => '语气跳脱，可轻微拖音',
    _Emotion.gentle => '放慢换气，留白多一些',
    _Emotion.serious => '减少花哨起伏，强调重点词',
    _Emotion.narrative => '像在讲故事，场景切换时换气',
  };

  String? get paceOverride => switch (this) {
    _Emotion.excited || _Emotion.happy || _Emotion.playful => '语速稍快，有弹性',
    _Emotion.sad || _Emotion.gentle || _Emotion.tender => '语速稍慢，留白更多',
    _Emotion.angry => '语速偏快，短句干脆',
    _ => null,
  };
}

const Map<_Emotion, List<String>> _lexicon = {
  _Emotion.happy: [
    '开心',
    '高兴',
    '快乐',
    '太好了',
    '真棒',
    '恭喜',
    '幸福',
    '喜欢',
    '哈哈',
    '耶',
  ],
  _Emotion.excited: [
    '激动',
    '兴奋',
    '太棒',
    '冲啊',
    '出发',
    '加油',
    '胜利',
    '终于',
    '哇',
    '天哪',
  ],
  _Emotion.tender: [
    '温柔',
    '抱抱',
    '想你',
    '安心',
    '陪伴',
    '晚安',
    '小心',
    '慢慢来',
    '没关系',
  ],
  _Emotion.sad: [
    '难过',
    '伤心',
    '失望',
    '遗憾',
    '哭',
    '眼泪',
    '孤独',
    '抱歉',
    '对不起',
    '失去',
  ],
  _Emotion.angry: [
    '生气',
    '愤怒',
    '可恶',
    '混蛋',
    '岂有此理',
    '受够了',
    '滚',
    '烦死',
  ],
  _Emotion.curious: [
    '为什么',
    '怎么会',
    '难道',
    '是不是',
    '什么情况',
    '好奇',
    '究竟',
  ],
  _Emotion.playful: [
    '哼',
    '才不是',
    '笨蛋',
    '讨厌',
    '啦',
    '嘛',
    '嘻嘻',
    '偷偷',
    '骗你的',
  ],
  _Emotion.gentle: ['或许', '也许', '静静', '慢慢', '仿佛', '微风', '月光', '回忆'],
  _Emotion.serious: [
    '因此',
    '总之',
    '需要注意',
    '重要',
    '必须',
    '结论',
    '分析',
    '建议',
  ],
  _Emotion.narrative: ['从前', '故事', '那天', '后来', '忽然', '只见', '远处', '夜色'],
  _Emotion.warm: ['谢谢', '麻烦你', '请', '你好', '欢迎', '一起'],
};
