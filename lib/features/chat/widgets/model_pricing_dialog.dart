import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/model_pricing.dart';
import 'settings_field_section.dart';

Future<void> showModelPricing(
  BuildContext context,
  WidgetRef ref,
  Set<String> keys,
) async {
  if (keys.isEmpty) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ModelPricingDialog(keys: Set.unmodifiable(keys)),
  );
}

class _ModelPricingDialog extends ConsumerStatefulWidget {
  const _ModelPricingDialog({required this.keys});
  final Set<String> keys;
  @override
  ConsumerState<_ModelPricingDialog> createState() =>
      _ModelPricingDialogState();
}

class _ModelPricingDialogState extends ConsumerState<_ModelPricingDialog> {
  final input = TextEditingController(),
      cached = TextEditingController(),
      output = TextEditingController(),
      currency = TextEditingController();
  late String selectedKey;
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    selectedKey = widget.keys.first;
    load();
  }

  void load() {
    final rate = ref.read(modelPricingProvider)[selectedKey];
    input.text = rate?.input.toString() ?? '';
    cached.text = rate?.cached.toString() ?? '';
    output.text = rate?.output.toString() ?? '';
    currency.text = rate?.currency ?? 'CNY';
  }

  @override
  void dispose() {
    input.dispose();
    cached.dispose();
    output.dispose();
    currency.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await ref
          .read(modelPricingProvider.notifier)
          .save(
            selectedKey,
            ModelRate(
              input: double.parse(input.text),
              cached: double.parse(cached.text),
              output: double.parse(output.text),
              currency: currency.text.trim().toUpperCase(),
            ),
          );
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '请检查单价：$e';
        });
      }
    }
  }

  String label(String key) {
    final parts = jsonDecode(key) as List;
    return '${parts.last} · ${Uri.tryParse(parts.first.toString())?.host ?? parts.first}';
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: const Text('模型费用估算'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('按服务商实际单价和 token 用量估算，不含工具或平台附加费。'),
            SettingsFieldSection(
              title: '模型与服务',
              child: InputDecorator(
                decoration: settingsControlDecoration,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    isDense: true,
                    value: selectedKey,
                    items: [
                      for (final key in widget.keys)
                        DropdownMenuItem(
                          value: key,
                          child: Text(
                            label(key),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: saving
                        ? null
                        : (value) => setState(() {
                            selectedKey = value!;
                            load();
                          }),
                  ),
                ),
              ),
            ),
            SettingsFieldSection(
              title: '币种',
              child: TextField(
                controller: currency,
                enabled: !saving,
                decoration: settingsControlDecoration.copyWith(
                  hintText: '例如 CNY / USD',
                ),
              ),
            ),
            for (final field in [
              (input, '输入 / 百万 token'),
              (cached, '缓存输入 / 百万 token'),
              (output, '输出 / 百万 token'),
            ])
              SettingsFieldSection(
                title: field.$2,
                child: TextField(
                  controller: field.$1,
                  enabled: !saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: settingsControlDecoration,
                ),
              ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? '保存中…' : '保存单价'),
        ),
      ],
    ),
  );
}
