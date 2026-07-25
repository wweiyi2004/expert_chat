import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/story_models.dart';

class WorldInfoController extends AsyncNotifier<List<WorldInfoEntry>> {
  @override
  Future<List<WorldInfoEntry>> build() =>
      ref.read(worldInfoRepositoryProvider).loadAll();

  Future<void> refresh() async {
    state = AsyncData(await ref.read(worldInfoRepositoryProvider).loadAll());
  }

  Future<void> save(WorldInfoEntry entry) async {
    await ref.read(worldInfoRepositoryProvider).save(entry);
    await refresh();
  }

  Future<void> delete(String id) async {
    await ref.read(worldInfoRepositoryProvider).delete(id);
    await refresh();
  }
}

final worldInfoProvider =
    AsyncNotifierProvider<WorldInfoController, List<WorldInfoEntry>>(
      WorldInfoController.new,
    );
