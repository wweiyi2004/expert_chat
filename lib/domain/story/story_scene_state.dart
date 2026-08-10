import 'package:characters/characters.dart';

import '../../data/models.dart';
import '../../data/story_models.dart';

/// A compact, deterministic snapshot of the scene being written this turn.
///
/// It is derived from persisted story metadata and recent prose, so existing
/// conversations gain scene-aware prompts without a database migration.
class StorySceneState {
  const StorySceneState({
    required this.beatIndex,
    required this.beatCount,
    required this.objective,
    required this.completedBeats,
    required this.activeCharacterNames,
    required this.continuityExcerpt,
  });

  final int beatIndex;
  final int beatCount;
  final String objective;
  final List<String> completedBeats;
  final List<String> activeCharacterNames;
  final String continuityExcerpt;

  bool get outlineComplete => beatCount > 0 && beatIndex >= beatCount;

  static StorySceneState derive({
    required Conversation conversation,
    required List<CharacterCard> cast,
    required List<ChatMessage> historyPath,
  }) {
    final beats = conversation.outlineBeats;
    final cursor = conversation.plotCursor.clamp(0, beats.length);
    final objective = cursor < beats.length ? beats[cursor] : '';
    final completed = cursor <= 0
        ? const <String>[]
        : beats
              .take(cursor)
              .toList()
              .reversed
              .take(3)
              .toList()
              .reversed
              .toList();

    final recentText = historyPath.reversed
        .where((message) => message.kind != MessageKind.generatedImage)
        .take(4)
        .map((message) => message.content)
        .join('\n');
    final relevanceText = '$objective\n$recentText'.toLowerCase();
    var active = [
      for (final character in cast)
        if (character.name.trim().isNotEmpty &&
            relevanceText.contains(character.name.trim().toLowerCase()))
          character.name.trim(),
    ];
    // A beat may use pronouns instead of names. Keep a small usable cast rather
    // than dropping every character, while avoiding a full-card dump for large
    // ensembles.
    if (active.isEmpty) {
      active = [for (final character in cast.take(4)) character.name.trim()];
    }

    var continuity = '';
    for (final message in historyPath.reversed) {
      if (message.role != MessageRole.assistant ||
          message.kind == MessageKind.generatedImage ||
          message.content.trim().isEmpty) {
        continue;
      }
      final chars = message.content.trim().characters;
      continuity = chars.length <= 600
          ? chars.toString()
          : '…${chars.skip(chars.length - 600)}';
      break;
    }

    return StorySceneState(
      beatIndex: cursor,
      beatCount: beats.length,
      objective: objective,
      completedBeats: List.unmodifiable(completed),
      activeCharacterNames: List.unmodifiable(
        active.where((name) => name.isNotEmpty),
      ),
      continuityExcerpt: continuity,
    );
  }
}
