import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../data/provider_profile.dart';

final modelServiceRoutingProvider =
    NotifierProvider<ModelServiceRouting, Map<String, List<String>>>(
      ModelServiceRouting.new,
    );

class ModelServiceRouting extends Notifier<Map<String, List<String>>> {
  static const storageKey = 'modelServicePriorities';
  Future<void> _pending = Future.value();
  @override
  Map<String, List<String>> build() {
    final raw = ref.read(sharedPrefsProvider).getString(storageKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map<String, dynamic>).map(
      (model, ids) => MapEntry(model, (ids as List).cast<String>()),
    );
  }

  Future<void> reorder(String model, List<String> ids) {
    final operation = _pending.then((_) async {
      final next = {...state, model: List<String>.of(ids)};
      if (!await ref
          .read(sharedPrefsProvider)
          .setString(storageKey, jsonEncode(next))) {
        throw StateError('优先级保存失败');
      }
      if (ref.mounted) state = next;
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}

List<ProviderProfile> servicesForModel(
  String model,
  List<ProviderProfile> profiles,
  Map<String, List<String>> priorities,
) {
  final available = profiles
      .where(
        (p) =>
            p.enabled &&
            (p.models.contains(model) ||
                p.chatModel == model ||
                p.reasonerModel == model),
      )
      .toList();
  final ordered = priorities[model] ?? const <String>[];
  available.sort((a, b) {
    final ai = ordered.indexOf(a.id), bi = ordered.indexOf(b.id);
    return (ai < 0 ? ordered.length + profiles.indexOf(a) : ai).compareTo(
      bi < 0 ? ordered.length + profiles.indexOf(b) : bi,
    );
  });
  return available;
}

List<String> serviceModelCatalog(List<ProviderProfile> profiles) => {
  for (final profile in profiles) ...[
    ...profile.models,
    profile.chatModel,
    profile.reasonerModel,
  ],
}.where((model) => model.trim().isNotEmpty).toList()..sort();
