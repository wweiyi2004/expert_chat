import 'dart:convert';

import '../../data/story_models.dart';

/// JSON import/export for character cards and world-info entries.
///
/// Formats are Expert Chat–native (`expert_chat.character` / `.world_info`) and
/// also accept a few SillyTavern-style field aliases on import.
class StudioAssetCodec {
  const StudioAssetCodec();

  static const characterFormat = 'expert_chat.character';
  static const charactersFormat = 'expert_chat.characters';
  static const worldInfoFormat = 'expert_chat.world_info';
  static const formatVersion = 1;

  // —— Character ————————————————————————————————————————————————

  String encodeCharacter(CharacterCard card, {bool pretty = true}) {
    final payload = {
      'format': characterFormat,
      'version': formatVersion,
      'character': _characterBody(card),
    };
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(payload)
        : jsonEncode(payload);
  }

  String encodeCharacters(List<CharacterCard> cards, {bool pretty = true}) {
    final payload = {
      'format': charactersFormat,
      'version': formatVersion,
      'characters': [for (final c in cards) _characterBody(c)],
    };
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(payload)
        : jsonEncode(payload);
  }

  /// Parses one or many character cards. Always mints new ids so imports add
  /// rather than silently overwrite existing library rows.
  List<CharacterCard> decodeCharacters(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return [
        for (final item in decoded)
          if (item is Map)
            _characterFromLoose(Map<String, dynamic>.from(item)),
      ];
    }
    if (decoded is! Map) {
      throw const FormatException('角色卡 JSON 格式无法识别。');
    }
    final map = Map<String, dynamic>.from(decoded);
    final format = map['format'] as String?;

    if (format == charactersFormat || map['characters'] is List) {
      final list = map['characters'] as List? ?? const [];
      return [
        for (final item in list)
          if (item is Map)
            _characterFromLoose(Map<String, dynamic>.from(item)),
      ];
    }

    final body = map['character'] is Map
        ? Map<String, dynamic>.from(map['character'] as Map)
        : map;
    return [_characterFromLoose(body)];
  }

  Map<String, dynamic> _characterBody(CharacterCard card) => {
    'name': card.name,
    'description': card.description,
    'personality': card.personality,
    'scenario': card.scenario,
    'firstMes': card.firstMes,
    'exampleDialogs': card.exampleDialogs,
    'systemPrompt': card.systemPrompt,
  };

  CharacterCard _characterFromLoose(Map<String, dynamic> json) {
    // data.character nested in some ST / Chub wrappers
    final data = json['data'] is Map
        ? Map<String, dynamic>.from(json['data'] as Map)
        : json;
    String pick(List<String> keys) {
      for (final key in keys) {
        final value = data[key] ?? json[key];
        if (value is String && value.trim().isNotEmpty) return value;
      }
      return '';
    }

    final name = pick(const ['name', 'char_name']);
    return CharacterCard(
      name: name.trim().isEmpty ? '未命名角色' : name.trim(),
      description: pick(const ['description', 'char_persona']),
      personality: pick(const ['personality', 'personality_summary']),
      scenario: pick(const ['scenario', 'world_scenario']),
      firstMes: pick(const ['firstMes', 'first_mes', 'first_message']),
      exampleDialogs: pick(const [
        'exampleDialogs',
        'mes_example',
        'example_dialogue',
        'example_dialogs',
      ]),
      systemPrompt: pick(const [
        'systemPrompt',
        'system_prompt',
        'system',
        'post_history_instructions',
      ]),
    );
  }

  // —— World info ——————————————————————————————————————————————

  String encodeWorldInfoEntries(
    List<WorldInfoEntry> entries, {
    bool pretty = true,
  }) {
    final payload = {
      'format': worldInfoFormat,
      'version': formatVersion,
      'entries': [for (final e in entries) _worldInfoBody(e)],
    };
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(payload)
        : jsonEncode(payload);
  }

  String encodeWorldInfoEntry(WorldInfoEntry entry, {bool pretty = true}) =>
      encodeWorldInfoEntries([entry], pretty: pretty);

  /// Parses one entry, a list of entries, or an Expert Chat pack.
  List<WorldInfoEntry> decodeWorldInfoEntries(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return [
        for (final item in decoded)
          if (item is Map)
            _worldInfoFromLoose(Map<String, dynamic>.from(item)),
      ];
    }
    if (decoded is! Map) {
      throw const FormatException('世界书 JSON 格式无法识别。');
    }
    final map = Map<String, dynamic>.from(decoded);
    if (map['entries'] is List) {
      final list = map['entries'] as List;
      return [
        for (final item in list)
          if (item is Map)
            _worldInfoFromLoose(Map<String, dynamic>.from(item)),
      ];
    }
    // Single entry object (title/content at top level).
    if (map['content'] != null || map['title'] != null || map['keys'] != null) {
      return [_worldInfoFromLoose(map)];
    }
    throw const FormatException('世界书 JSON 中没有找到条目。');
  }

  Map<String, dynamic> _worldInfoBody(WorldInfoEntry entry) => {
    'title': entry.title,
    'keys': entry.keys,
    'content': entry.content,
    'alwaysOn': entry.alwaysOn,
    'enabled': entry.enabled,
    'priority': entry.priority,
  };

  WorldInfoEntry _worldInfoFromLoose(Map<String, dynamic> json) {
    final keysRaw = json['keys'] ?? json['key'] ?? json['keywords'];
    List<String> keys;
    if (keysRaw is List) {
      keys = [
        for (final k in keysRaw)
          if (k != null && k.toString().trim().isNotEmpty) k.toString().trim(),
      ];
    } else if (keysRaw is String) {
      keys = keysRaw
          .split(RegExp(r'[,，、|]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } else {
      keys = const [];
    }

    final title = (json['title'] ?? json['name'] ?? json['comment'] ?? '')
        .toString();
    final content = (json['content'] ?? json['entry'] ?? json['value'] ?? '')
        .toString();
    final alwaysOn =
        json['alwaysOn'] as bool? ??
        json['constant'] as bool? ??
        json['always_active'] as bool? ??
        false;
    final enabled = json['enabled'] as bool? ?? json['disable'] != true;
    final priority =
        (json['priority'] as num?)?.toInt() ??
        (json['order'] as num?)?.toInt() ??
        0;

    return WorldInfoEntry(
      title: title.trim().isEmpty ? '未命名条目' : title.trim(),
      keys: keys,
      content: content,
      alwaysOn: alwaysOn,
      enabled: enabled,
      priority: priority,
    );
  }
}
