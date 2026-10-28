import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../domain/workbench/agents/role_trial_validator.dart';

final roleTrialValidatorProvider = Provider((ref) => RoleTrialValidator());
final roleValidationSettingsProvider =
    NotifierProvider<RoleValidationSettingsController, RoleValidationConfig>(
      RoleValidationSettingsController.new,
    );

class RoleValidationSettingsController extends Notifier<RoleValidationConfig> {
  static const storageKey = 'roleValidation.v1';
  Future<void> _pending = Future.value();
  @override
  RoleValidationConfig build() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(storageKey);
      if (raw == null) return const RoleValidationConfig();
      final data = jsonDecode(raw) as Map;
      return RoleValidationConfig(
        enabled: data['enabled'] == true,
        autoPromote: data['autoPromote'] == true,
        model: data['model'] as String? ?? '__current__',
        maxReviewsPerTask: ((data['maxReviewsPerTask'] as num?)?.toInt() ?? 2)
            .clamp(1, 5),
        prompt: data['prompt'] as String? ?? defaultRoleValidationPrompt,
      );
    } catch (_) {
      return const RoleValidationConfig();
    }
  }

  Future<void> save(RoleValidationConfig next) {
    if (next.prompt.length > 16000 ||
        next.maxReviewsPerTask < 1 ||
        next.maxReviewsPerTask > 5) {
      throw ArgumentError('角色验收设置超限');
    }
    final operation = _pending.then((_) async {
      if (!await ref
          .read(sharedPrefsProvider)
          .setString(
            storageKey,
            jsonEncode({
              'enabled': next.enabled,
              'autoPromote': next.autoPromote,
              'model': next.model,
              'maxReviewsPerTask': next.maxReviewsPerTask,
              'prompt': next.prompt,
            }),
          )) {
        throw StateError('验收配置保存失败');
      }
      if (ref.mounted) state = next;
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}
