import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';

const modelGroupPrefix = '__group__:';

class ModelRouteGroup {
  const ModelRouteGroup({
    required this.id,
    required this.name,
    required this.models,
    this.failover = false,
  });
  final String id, name;
  final List<String> models;
  final bool failover;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'models': models,
    'failover': failover,
  };
  factory ModelRouteGroup.fromJson(Map data) => ModelRouteGroup(
    id: data['id'] as String,
    name: data['name'] as String,
    models: (data['models'] as List).cast<String>(),
    failover: data['failover'] == true,
  );
}

class ModelRoutePolicy {
  const ModelRoutePolicy({this.groups = const [], this.autoGroup = ''});
  final List<ModelRouteGroup> groups;
  final String autoGroup;
}

final modelRouteGroupsProvider =
    NotifierProvider<ModelRouteGroupsController, ModelRoutePolicy>(
      ModelRouteGroupsController.new,
    );

class ModelRouteGroupsController extends Notifier<ModelRoutePolicy> {
  static const storageKey = 'modelRouteGroups.v1';
  Future<void> _pending = Future.value();
  @override
  ModelRoutePolicy build() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(storageKey);
      if (raw == null) return const ModelRoutePolicy();
      final data = jsonDecode(raw) as Map;
      return ModelRoutePolicy(
        groups: (data['groups'] as List)
            .map((g) => ModelRouteGroup.fromJson(g as Map))
            .toList(),
        autoGroup: data['autoGroup'] as String? ?? '',
      );
    } catch (_) {
      return const ModelRoutePolicy();
    }
  }

  Future<void> save(List<ModelRouteGroup> groups, {String? autoGroup}) {
    if (groups.length > 20 ||
        groups.any(
          (g) =>
              g.name.trim().isEmpty ||
              g.models.isEmpty ||
              g.models.length > 20 ||
              g.models.toSet().length != g.models.length,
        ) ||
        groups.map((g) => g.id).toSet().length != groups.length) {
      throw ArgumentError('路由组最多 20 个，每组 1–20 个不同模型');
    }
    final operation = _pending.then((_) async {
      final next = ModelRoutePolicy(
        groups: List.unmodifiable(groups),
        autoGroup: autoGroup ?? state.autoGroup,
      );
      if (!await ref
          .read(sharedPrefsProvider)
          .setString(
            storageKey,
            jsonEncode({
              'groups': groups.map((g) => g.toJson()).toList(),
              'autoGroup': next.autoGroup,
            }),
          )) {
        throw StateError('路由组保存失败');
      }
      if (ref.mounted) state = next;
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}
