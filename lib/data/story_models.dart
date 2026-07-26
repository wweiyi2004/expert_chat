import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Chat vs story (character / novel) vs multi-character ensemble session.
enum ConversationMode {
  chat,
  story,

  /// Multiple character cards in one venue, taking turns.
  ensemble;

  String get wire => name;

  static ConversationMode fromWire(String? value) {
    if (value == ConversationMode.story.wire) return ConversationMode.story;
    if (value == ConversationMode.ensemble.wire) {
      return ConversationMode.ensemble;
    }
    return ConversationMode.chat;
  }
}

/// A reusable character card (SillyTavern-style fields, app-edited only).
class CharacterCard {
  CharacterCard({
    String? id,
    required this.name,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMes = '',
    this.exampleDialogs = '',
    this.systemPrompt = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? _uuid.v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMes;
  final String exampleDialogs;
  final String systemPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;

  CharacterCard copyWith({
    String? name,
    String? description,
    String? personality,
    String? scenario,
    String? firstMes,
    String? exampleDialogs,
    String? systemPrompt,
    DateTime? updatedAt,
  }) => CharacterCard(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    personality: personality ?? this.personality,
    scenario: scenario ?? this.scenario,
    firstMes: firstMes ?? this.firstMes,
    exampleDialogs: exampleDialogs ?? this.exampleDialogs,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'personality': personality,
    'scenario': scenario,
    'firstMes': firstMes,
    'exampleDialogs': exampleDialogs,
    'systemPrompt': systemPrompt,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory CharacterCard.fromJson(Map<String, dynamic> json) => CharacterCard(
    id: json['id'] as String?,
    name: json['name'] as String? ?? '未命名角色',
    description: json['description'] as String? ?? '',
    personality: json['personality'] as String? ?? '',
    scenario: json['scenario'] as String? ?? '',
    firstMes: json['firstMes'] as String? ?? '',
    exampleDialogs: json['exampleDialogs'] as String? ?? '',
    systemPrompt: json['systemPrompt'] as String? ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
  );
}

/// One world-info / lorebook entry (global library; sessions opt in by id).
class WorldInfoEntry {
  WorldInfoEntry({
    String? id,
    required this.title,
    List<String>? keys,
    this.content = '',
    this.alwaysOn = false,
    this.enabled = true,
    this.priority = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? _uuid.v4(),
       keys = keys ?? const [],
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String title;
  final List<String> keys;
  final String content;
  final bool alwaysOn;
  final bool enabled;
  final int priority;
  final DateTime createdAt;
  final DateTime updatedAt;

  WorldInfoEntry copyWith({
    String? title,
    List<String>? keys,
    String? content,
    bool? alwaysOn,
    bool? enabled,
    int? priority,
    DateTime? updatedAt,
  }) => WorldInfoEntry(
    id: id,
    title: title ?? this.title,
    keys: keys ?? this.keys,
    content: content ?? this.content,
    alwaysOn: alwaysOn ?? this.alwaysOn,
    enabled: enabled ?? this.enabled,
    priority: priority ?? this.priority,
    createdAt: createdAt,
    updatedAt: updatedAt ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'keys': keys,
    'content': content,
    'alwaysOn': alwaysOn,
    'enabled': enabled,
    'priority': priority,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory WorldInfoEntry.fromJson(Map<String, dynamic> json) => WorldInfoEntry(
    id: json['id'] as String?,
    title: json['title'] as String? ?? '',
    keys: (json['keys'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList(),
    content: json['content'] as String? ?? '',
    alwaysOn: json['alwaysOn'] as bool? ?? false,
    enabled: json['enabled'] as bool? ?? true,
    priority: (json['priority'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
  );
}

/// Split an outline into ordered plot beats.
///
/// Each non-empty line is one beat. Markdown headers (`#`), bullets (`-`/`*`),
/// and numbered lists are stripped to their title text.
List<String> parseOutlineBeats(String outline) {
  final beats = <String>[];
  for (final raw in outline.split(RegExp(r'\r?\n'))) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    line = line
        .replaceFirst(RegExp(r'^#+\s*'), '')
        .replaceFirst(RegExp(r'^[-*•]\s+'), '')
        .replaceFirst(RegExp(r'^\d+[.)、]\s*'), '')
        .trim();
    if (line.isNotEmpty) beats.add(line);
  }
  return beats;
}
