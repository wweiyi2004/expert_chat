import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../domain/workbench/agents/task_supervisor.dart';

final supervisorSettingsProvider =
    NotifierProvider<SupervisorSettingsController, SupervisorConfig>(
      SupervisorSettingsController.new,
    );

class SupervisorSettingsController extends Notifier<SupervisorConfig> {
  static const storageKey = 'taskSupervisor.v1';
  Future<void> _pending = Future.value();
  @override
  SupervisorConfig build() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(storageKey);
      if (raw == null) return const SupervisorConfig();
      final data = jsonDecode(raw) as Map;
      return SupervisorConfig(
        enabled: data['enabled'] == true,
        model: data['model'] as String? ?? '',
        maxReviews: ((data['maxReviews'] as num?)?.toInt() ?? 3).clamp(1, 10),
        minRoundGap: ((data['minRoundGap'] as num?)?.toInt() ?? 2).clamp(1, 10),
        prompt: data['prompt'] as String? ?? defaultSupervisorPrompt,
      );
    } catch (_) {
      return const SupervisorConfig();
    }
  }

  Future<void> save(SupervisorConfig next) {
    if (next.maxReviews < 1 ||
        next.maxReviews > 10 ||
        next.minRoundGap < 1 ||
        next.minRoundGap > 10 ||
        next.prompt.length > 16000) {
      throw ArgumentError('监督配置超出限制');
    }
    final operation = _pending.then((_) async {
      if (!await ref
          .read(sharedPrefsProvider)
          .setString(
            storageKey,
            jsonEncode({
              'enabled': next.enabled,
              'model': next.model,
              'maxReviews': next.maxReviews,
              'minRoundGap': next.minRoundGap,
              'prompt': next.prompt,
            }),
          )) {
        throw StateError('监督配置保存失败');
      }
      if (ref.mounted) state = next;
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}
