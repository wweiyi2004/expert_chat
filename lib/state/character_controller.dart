import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/story_models.dart';

class CharacterCardsController extends AsyncNotifier<List<CharacterCard>> {
  @override
  Future<List<CharacterCard>> build() =>
      ref.read(characterRepositoryProvider).loadAll();

  Future<void> refresh() async {
    state = AsyncData(await ref.read(characterRepositoryProvider).loadAll());
  }

  Future<void> save(CharacterCard card) async {
    await ref.read(characterRepositoryProvider).save(card);
    await refresh();
  }

  Future<void> delete(String id) async {
    await ref.read(characterRepositoryProvider).delete(id);
    await refresh();
  }
}

final characterCardsProvider =
    AsyncNotifierProvider<CharacterCardsController, List<CharacterCard>>(
      CharacterCardsController.new,
    );
