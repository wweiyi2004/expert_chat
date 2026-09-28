import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../data/jev_config.dart';
import '../../../domain/llm/jev_client.dart';
import 'debounced_secret_field.dart';

class JevSettingsCard extends StatefulWidget {
  const JevSettingsCard({
    super.key,
    required this.config,
    required this.apiKey,
    required this.client,
    required this.onConfigChanged,
    required this.onApiKeySaved,
  });

  final JevConfig config;
  final String apiKey;
  final JevClient client;
  final Future<void> Function(JevConfig) onConfigChanged;
  final Future<void> Function(String) onApiKeySaved;

  @override
  State<JevSettingsCard> createState() => _JevSettingsCardState();
}

class _JevSettingsCardState extends State<JevSettingsCard> {
  CancelToken? _testCancel;
  String? _result;
  bool _saving = false;

  @override
  void didUpdateWidget(JevSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiKey != widget.apiKey ||
        oldWidget.config.model != widget.config.model) {
      _testCancel?.cancel();
      _testCancel = null;
      _result = null;
    }
  }

  @override
  void dispose() {
    _testCancel?.cancel();
    super.dispose();
  }

  Future<void> _save(JevConfig config) async {
    setState(() => _saving = true);
    try {
      await widget.onConfigChanged(config);
    } catch (_) {
      if (mounted) setState(() => _result = '保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    final cancel = CancelToken();
    setState(() {
      _testCancel = cancel;
      _result = null;
    });
    final watch = Stopwatch()..start();
    try {
      final answer = await widget.client.choose(
        apiKey: widget.apiKey,
        model: widget.config.model,
        state: '请把这句话翻译成英语：你好。',
        instructions: '选择最适合处理这条消息的技能。',
        criteria: const {'translate': '翻译文本', 'code': '编写或调试代码'},
        cancelToken: cancel,
      );
      if (!mounted || cancel.isCancelled) return;
      setState(
        () => _result =
            '连接成功 · ${watch.elapsedMilliseconds} 毫秒 · '
            '分类：${answer.choice == 'translate' ? '翻译' : '编程'} · '
            '置信度 ${(answer.confidence * 100).toStringAsFixed(0)}%',
      );
    } on JevException catch (error) {
      if (mounted && !cancel.isCancelled) {
        setState(() => _result = error.message);
      }
    } catch (_) {
      if (mounted && !cancel.isCancelled) {
        setState(() => _result = '连接失败，请检查配置后重试。');
      }
    } finally {
      if (mounted && identical(_testCancel, cancel)) {
        setState(() => _testCancel = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Jev 技能自动路由'),
        value: widget.config.enabled,
        onChanged: _saving
            ? null
            : (value) => _save(widget.config.copyWith(enabled: value)),
      ),
      const Text(
        '开启后会将本轮消息（最多 8,000 字符）及最近 4 条对话'
        '（每条最多 400 字符）发送给 TypeSafe。'
        '明确指定技能时跳过分类；超时或置信度不足时使用通用提示词。'
        '关闭或未填写密钥时沿用聊天模型分类。',
      ),
      const SizedBox(height: 12),
      DebouncedSecretField(
        key: const ValueKey('jev_api_key'),
        value: widget.apiKey,
        onSaved: widget.onApiKeySaved,
        decoration: const InputDecoration(
          labelText: 'TypeSafe API Key',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      DebouncedSecretField(
        key: const ValueKey('jev_model'),
        value: widget.config.model,
        obscureText: false,
        onSaved: (value) =>
            widget.onConfigChanged(widget.config.copyWith(model: value)),
        decoration: const InputDecoration(
          labelText: 'Jev 模型',
          hintText: 'jev-latest',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<double>(
        key: ValueKey(widget.config.minConfidence),
        initialValue: widget.config.minConfidence,
        decoration: const InputDecoration(labelText: '最低分类置信度'),
        items:
            (<double>{
                  0.5,
                  0.6,
                  0.7,
                  0.8,
                  0.9,
                  widget.config.minConfidence,
                }.toList()..sort())
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text('${(value * 100).toStringAsFixed(0)}%'),
                  ),
                )
                .toList(),
        onChanged: _saving
            ? null
            : (value) {
                if (value != null) {
                  _save(widget.config.copyWith(minConfidence: value));
                }
              },
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        children: [
          OutlinedButton.icon(
            onPressed: widget.apiKey.trim().isEmpty || _testCancel != null
                ? null
                : _test,
            icon: const Icon(Icons.network_check),
            label: Text(_testCancel == null ? '测试 Jev 连接' : '正在测试…'),
          ),
          if (_testCancel != null)
            TextButton(
              onPressed: () {
                _testCancel?.cancel();
                setState(() {
                  _testCancel = null;
                  _result = '已取消测试。';
                });
              },
              child: const Text('取消测试'),
            ),
        ],
      ),
      const Text('测试仅发送一条固定翻译样例，不携带聊天记录，可能产生少量用量。'),
      if (_result != null) ...[
        const SizedBox(height: 8),
        Text(_result!, key: const ValueKey('jev_test_result')),
      ],
    ],
  );
}
