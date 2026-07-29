import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/story/story_ai_assist.dart';

/// Locally persisted, unfinished state from the director-story setup page.
///
/// This is intentionally separate from [Conversation]: setup work should
/// survive an accidental back navigation or process restart, but should not
/// appear in conversation history until the user explicitly starts the story.
class DirectorStorySetupDraft {
  const DirectorStorySetupDraft({
    this.premise = '',
    this.requirements = '',
    this.styleIds = const [],
    this.beatCount = 8,
    this.targetTotalChars = 80000,
    this.strictReview = true,
    this.generatedDraft,
    this.generationFingerprint = '',
    this.savedAt,
  });

  static const schemaVersion = 1;

  final String premise;
  final String requirements;
  final List<String> styleIds;
  final int beatCount;
  final int targetTotalChars;
  final bool strictReview;

  /// AI-generated cast plus the user's latest title/outline/director-note
  /// edits. Null before the first plan has been generated.
  final DirectorStoryDraft? generatedDraft;

  /// Input signature used to generate [generatedDraft]. It stays unchanged
  /// when the user edits output fields, but lets the setup page detect changes
  /// to the premise, prose constraints, beat count, length or review mode.
  final String generationFingerprint;
  final DateTime? savedAt;

  bool get hasMeaningfulContent =>
      premise.trim().isNotEmpty ||
      requirements.trim().isNotEmpty ||
      styleIds.isNotEmpty ||
      beatCount != 8 ||
      targetTotalChars != 80000 ||
      !strictReview ||
      generatedDraft != null;

  Map<String, dynamic> toJson() => {
    'version': schemaVersion,
    'premise': premise,
    'requirements': requirements,
    'styleIds': styleIds,
    'beatCount': beatCount,
    'targetTotalChars': targetTotalChars,
    'strictReview': strictReview,
    if (generatedDraft != null) 'generatedDraft': generatedDraft!.toJson(),
    if (generationFingerprint.isNotEmpty)
      'generationFingerprint': generationFingerprint,
    'savedAt': (savedAt ?? DateTime.now()).toIso8601String(),
  };

  static DirectorStorySetupDraft? fromJsonMap(Map<String, dynamic>? json) {
    if (json == null || json['version'] != schemaVersion) return null;

    final rawStyles = json['styleIds'];
    final generated = json['generatedDraft'];
    return DirectorStorySetupDraft(
      premise: json['premise'] is String ? json['premise'] as String : '',
      requirements: json['requirements'] is String
          ? json['requirements'] as String
          : '',
      styleIds: rawStyles is List
          ? rawStyles
                .whereType<String>()
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList(growable: false)
          : const [],
      beatCount: (json['beatCount'] as num?)?.toInt() ?? 8,
      targetTotalChars: (json['targetTotalChars'] as num?)?.toInt() ?? 80000,
      strictReview: json['strictReview'] is bool
          ? json['strictReview'] as bool
          : true,
      generatedDraft: generated is Map
          ? DirectorStoryDraft.fromJsonMap(
              generated.map((key, value) => MapEntry(key.toString(), value)),
            )
          : null,
      generationFingerprint: json['generationFingerprint'] is String
          ? json['generationFingerprint'] as String
          : '',
      savedAt: DateTime.tryParse(json['savedAt'] as String? ?? ''),
    );
  }
}

class DirectorStorySetupDraftStore {
  DirectorStorySetupDraftStore(this._prefs);

  static const storageKey = 'directorStorySetupDraftV1';

  final SharedPreferences _prefs;

  DirectorStorySetupDraft? read() {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return DirectorStorySetupDraft.fromJsonMap(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(DirectorStorySetupDraft draft) async {
    if (!draft.hasMeaningfulContent) {
      await clear();
      return;
    }
    await _prefs.setString(storageKey, jsonEncode(draft.toJson()));
  }

  Future<void> clear() async {
    await _prefs.remove(storageKey);
  }
}
