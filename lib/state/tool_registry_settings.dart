import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../domain/tools/math/math_toolkit.dart';

class ToolRegistrySettings {
  const ToolRegistrySettings({
    this.mathEnabled = false,
    this.pythonExecutable = 'python',
  });
  final bool mathEnabled;
  final String pythonExecutable;
  MathToolkit get mathematics =>
      MathToolkit(pythonExecutable: pythonExecutable);
}

final toolRegistrySettingsProvider =
    NotifierProvider<ToolRegistryController, ToolRegistrySettings>(
      ToolRegistryController.new,
    );

class ToolRegistryController extends Notifier<ToolRegistrySettings> {
  static const storageKey = 'trustedToolRegistry.v1';
  Future<void> _pending = Future.value();
  @override
  ToolRegistrySettings build() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(storageKey);
      if (raw == null) return const ToolRegistrySettings();
      final data = jsonDecode(raw) as Map;
      return ToolRegistrySettings(
        mathEnabled: data['mathEnabled'] == true,
        pythonExecutable: data['pythonExecutable'] is String
            ? data['pythonExecutable'] as String
            : 'python',
      );
    } catch (_) {
      return const ToolRegistrySettings();
    }
  }

  Future<void> configure({bool? mathEnabled, String? pythonExecutable}) {
    final nextExecutable = pythonExecutable?.trim();
    if (nextExecutable != null &&
        (nextExecutable.isEmpty ||
            nextExecutable.length > 1024 ||
            nextExecutable.contains('\n'))) {
      throw ArgumentError('请输入 Python 可执行文件名称或完整路径，不包含命令参数');
    }
    final operation = _pending.then((_) async {
      final next = ToolRegistrySettings(
        mathEnabled: mathEnabled ?? state.mathEnabled,
        pythonExecutable: nextExecutable ?? state.pythonExecutable,
      );
      if (!await ref
          .read(sharedPrefsProvider)
          .setString(
            storageKey,
            jsonEncode({
              'mathEnabled': next.mathEnabled,
              'pythonExecutable': next.pythonExecutable,
            }),
          )) {
        throw StateError('工具设置保存失败');
      }
      if (ref.mounted) state = next;
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}
