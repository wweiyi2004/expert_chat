import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/provider_profile.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/llm/model_connection_tester.dart';
import '../../state/settings_controller.dart';
import '../shared/recovery_notice.dart';

final modelConnectionTesterProvider = Provider<ModelConnectionTester>(
  (ref) => ModelConnectionTester(ref.read(llmProvider)),
);

Future<bool> showModelSetup(BuildContext context) async =>
    await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const ModelSetupPage())) ??
    false;

class ModelSetupPage extends ConsumerStatefulWidget {
  const ModelSetupPage({super.key});
  @override
  ConsumerState<ModelSetupPage> createState() => _ModelSetupPageState();
}

class _ModelSetupPageState extends ConsumerState<ModelSetupPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  ProviderProfile? _original;
  String? _credentialHost;
  int _preset = -1;
  bool _obscure = true;
  bool _checking = false;
  bool _saving = false;
  CancelToken? _cancel;
  Duration? _verified;
  Object? _error;
  String? _notice;
  bool get _busy => _checking || _saving;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsControllerProvider).value;
    _original = settings?.active;
    final profile = _original ?? ProviderPreset.presets.first.toProfile();
    _name.text = profile.name;
    _url.text = profile.baseUrl;
    _model.text = settings?.active == null
        ? profile.chatModel
        : settings!.model;
    _key.text = settings?.apiKey ?? '';
    _credentialHost = Uri.tryParse(profile.baseUrl)?.host;
    _preset = ProviderPreset.presets.indexWhere(
      (p) => p.baseUrl == profile.baseUrl,
    );
  }

  @override
  void dispose() {
    _cancel?.cancel('setup closed');
    for (final controller in [_name, _url, _model, _key]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changed(String _) => setState(() {
    _verified = null;
    _error = null;
    _notice = null;
  });

  void _selectPreset(int value) {
    setState(() {
      _preset = value;
      _verified = null;
      _error = null;
      _notice = null;
      if (value >= 0) {
        final preset = ProviderPreset.presets[value];
        if (_url.text != preset.baseUrl) _key.clear();
        _name.text = preset.name;
        _url.text = preset.baseUrl;
        _credentialHost = Uri.tryParse(preset.baseUrl)?.host;
        _model.text = preset.chatModel;
      }
    });
  }

  String? _validateUrl(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return '请输入完整的 http:// 或 https:// 服务地址';
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return '请将密钥填在 API Key 中，服务地址不要包含登录信息、查询参数或片段';
    }
    if (uri.path.endsWith('/chat/completions') ||
        uri.path.endsWith('/responses')) {
      return '请填写基础地址，不包含 /chat/completions 或 /responses';
    }
    return null;
  }

  Future<void> _check() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _checking = true;
      _verified = null;
      _error = null;
      _notice = null;
    });
    final token = _cancel = CancelToken();
    try {
      final elapsed = await ref
          .read(modelConnectionTesterProvider)
          .check(
            LlmConfig(
              baseUrl: _url.text.trim().replaceFirst(RegExp(r'/+$'), ''),
              apiKey: _key.text.trim(),
              model: _model.text.trim(),
            ),
            cancelToken: token,
          );
      if (mounted) setState(() => _verified = elapsed);
    } catch (e) {
      if (!mounted) return;
      if (e is DioException && CancelToken.isCancel(e)) {
        setState(() => _notice = '测试已取消，填写内容已保留。');
      } else {
        setState(() => _error = e);
      }
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
          _cancel = null;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_busy || _verified == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final endpoint = _url.text.trim().replaceFirst(RegExp(r'/+$'), '');
    final existing =
        _original?.baseUrl.replaceFirst(RegExp(r'/+$'), '') == endpoint
        ? _original
        : null;
    final model = _model.text.trim();
    final profile = ProviderProfile(
      id: existing?.id,
      name: _name.text.trim().isEmpty
          ? Uri.parse(endpoint).host
          : _name.text.trim(),
      baseUrl: endpoint,
      chatModel: model,
      reasonerModel:
          existing?.reasonerModel ??
          (_preset >= 0
              ? ProviderPreset.presets[_preset].reasonerModel
              : model),
      models: {
        model,
        ...?existing?.models,
        if (_preset >= 0) ...ProviderPreset.presets[_preset].models,
      }.toList(),
    );
    try {
      await ref
          .read(settingsControllerProvider.notifier)
          .saveVerifiedConnection(profile, _key.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('连接你的模型')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Form(
                key: _form,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
                  children: [
                    Text(
                      '从第一条对话开始',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text('选择你使用的模型服务，验证连接后就可以开始聊天。'),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Chip(
                          labelStyle: Theme.of(context).textTheme.bodySmall,
                          label: Text(
                            _verified == null ? '1 · 填写并验证' : '1 · 连接已验证',
                          ),
                        ),
                        Chip(
                          labelStyle: Theme.of(context).textTheme.bodySmall,
                          label: const Text('2 · 保存并开始对话'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      key: ValueKey('setup-preset-$_preset'),
                      initialValue: _preset,
                      isExpanded: true,
                      menuMaxHeight: 360,
                      decoration: const InputDecoration(labelText: '服务商'),
                      items: [
                        for (var i = 0; i < ProviderPreset.presets.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              ProviderPreset.presets[i].name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: -1,
                          child: Text('自定义兼容服务'),
                        ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) {
                              if (v != null) _selectPreset(v);
                            },
                    ),
                    if (_preset == -1) ...[
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _name,
                        enabled: !_busy,
                        onChanged: _changed,
                        decoration: const InputDecoration(
                          labelText: '服务名称（可选）',
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const ValueKey('setup-url'),
                      controller: _url,
                      enabled: !_busy,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      validator: _validateUrl,
                      decoration: const InputDecoration(
                        labelText: '服务地址',
                        helperText: '预设已填写；自建或中转服务可修改',
                      ),
                      onChanged: (value) {
                        // A key copied from an existing profile must not silently
                        // travel to a different host when the endpoint is edited.
                        final host = Uri.tryParse(value)?.host;
                        if (host != _credentialHost) {
                          _key.clear();
                        }
                        _credentialHost = host;
                        _changed(value);
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const ValueKey('setup-key'),
                      controller: _key,
                      enabled: !_busy,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: _changed,
                      validator: (v) => (v?.trim().isEmpty ?? true)
                          ? '请填写该服务商的 API Key'
                          : null,
                      decoration: InputDecoration(
                        labelText: 'API Key',
                        helperText: '使用你在所选服务商处创建的密钥',
                        suffixIcon: IconButton(
                          tooltip: _obscure ? '显示密钥' : '隐藏密钥',
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(
                            _obscure ? Icons.visibility : Icons.visibility_off,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const ValueKey('setup-model'),
                      controller: _model,
                      enabled: !_busy,
                      onChanged: _changed,
                      autocorrect: false,
                      validator: (v) =>
                          (v?.trim().isEmpty ?? true) ? '请填写模型名称' : null,
                      decoration: const InputDecoration(
                        labelText: '模型名称',
                        helperText: '可使用预设，或填写账户已开通的模型',
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '密钥保存在本机系统安全存储中，仅用于向你配置的服务发送请求认证。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '连接测试会发送一条简短消息，可能产生少量用量；不会发送历史对话或资料。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 20),
                    if (_error != null) ...[
                      RecoveryNotice(
                        error: _error!,
                        secrets: [_key.text],
                        guidance: '填写内容已保留。请检查上方配置后再试。',
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_notice != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(_notice!),
                      ),
                    if (_verified != null) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Text('连接成功，模型已返回回复。保存后即可开始对话。'),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : _save,
                        child: Text(_saving ? '正在保存…' : '保存并开始对话'),
                      ),
                    ] else ...[
                      FilledButton(
                        onPressed: _busy ? null : _check,
                        child: Text(_checking ? '正在验证连接…' : '测试连接'),
                      ),
                      if (_checking)
                        TextButton(
                          onPressed: () =>
                              _cancel?.cancel('user cancelled test'),
                          child: const Text('取消测试'),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
