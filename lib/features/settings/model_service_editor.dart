import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/settings_form_style.dart';
import '../../data/provider_profile.dart';
import '../../data/model_token_limits.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/llm/model_discovery.dart';
import '../../state/settings_controller.dart';

class ModelServiceEditor extends ConsumerStatefulWidget {
  const ModelServiceEditor({super.key, this.profile, this.preset});
  final ProviderProfile? profile;
  final ProviderPreset? preset;
  @override
  ConsumerState<ModelServiceEditor> createState() => _ModelServiceEditorState();
}

class _ModelServiceEditorState extends ConsumerState<ModelServiceEditor> {
  final _name = TextEditingController(),
      _url = TextEditingController(),
      _key = TextEditingController(),
      _models = TextEditingController();
  final _form = GlobalKey<FormState>();
  CancelToken? _token;
  bool _busy = false, _loading = false, _obscure = true;
  String? _error;
  LlmApiFormat _format = LlmApiFormat.auto;
  String _authMode = 'apiKey';
  Map<String, ModelTokenLimits> _limits = {};
  String? _limitsEndpoint;
  @override
  void initState() {
    super.initState();
    final profile = widget.profile ?? widget.preset?.toProfile();
    if (profile != null) _fillProfile(profile);
    if (widget.profile != null) {
      _loading = true;
      ref
          .read(settingsControllerProvider.notifier)
          .readCurrentProfileCredentials(widget.profile!.id)
          .then(
            (snapshot) {
              if (mounted) {
                setState(() {
                  _fillProfile(snapshot.profile);
                  _key.text = snapshot.apiKey;
                  _loading = false;
                });
              }
            },
            onError: (Object error) {
              if (mounted) {
                setState(() {
                  _error = '$error';
                  _loading = false;
                });
              }
            },
          );
    }
  }

  void _fillProfile(ProviderProfile profile) {
    _name.text = profile.name;
    _url.text = profile.baseUrl;
    _models.text = {
      ...profile.models,
      profile.chatModel,
      profile.reasonerModel,
    }.where((m) => m.isNotEmpty).join('\n');
    _format = profile.apiFormat;
    _authMode = profile.authMode == 'none' ? 'none' : 'apiKey';
    _limits = {...profile.modelLimits};
    _limitsEndpoint = profile.baseUrl.replaceFirst(RegExp(r'/+$'), '');
  }

  @override
  void dispose() {
    _token?.cancel();
    for (final c in [_name, _url, _key, _models]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get models => _models.text
      .split(RegExp(r'[\n,，]+'))
      .map((m) => m.trim())
      .where((m) => m.isNotEmpty)
      .toSet()
      .toList();
  Future<void> _scan() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final token = _token = CancelToken();
    try {
      final discovery = ModelDiscovery();
      final list = await discovery.scan(
        LlmConfig(
          baseUrl: _url.text.trim(),
          apiKey: _key.text.trim(),
          model: '',
          apiFormat: _format,
          authMode: _authMode,
        ),
        token,
      );
      if (mounted) {
        setState(() {
          _models.text = list.join('\n');
          _limits = {...discovery.limits};
          _limitsEndpoint = _url.text.trim().replaceFirst(RegExp(r'/+$'), '');
        });
      }
    } catch (error) {
      if (mounted && !token.isCancelled) {
        setState(() => _error = '无法扫描模型：$error。可以手动填写模型 ID。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (models.isEmpty) {
      setState(() => _error = '请扫描模型，或至少填写一个模型 ID');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profile = ProviderProfile(
        id: widget.profile?.id,
        name: _name.text.trim().isEmpty
            ? Uri.parse(_url.text.trim()).host
            : _name.text.trim(),
        baseUrl: _url.text.trim().replaceFirst(RegExp(r'/+$'), ''),
        chatModel: models.first,
        reasonerModel: models.contains(widget.profile?.reasonerModel)
            ? widget.profile!.reasonerModel
            : models.first,
        models: models,
        modelLimits:
            _limitsEndpoint == _url.text.trim().replaceFirst(RegExp(r'/+$'), '')
            ? {
                for (final model in models)
                  if (_limits.containsKey(model)) model: _limits[model]!,
              }
            : {},
        apiFormat: _format,
        authMode: _authMode,
      );
      await ref
          .read(settingsControllerProvider.notifier)
          .saveModelService(profile, _key.text);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsFormStyle(
    child: Scaffold(
      appBar: AppBar(title: Text(widget.profile == null ? '添加模型服务' : '编辑模型服务')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                TextField(
                  controller: _name,
                  enabled: !_busy && !_loading,
                  decoration: const InputDecoration(labelText: '服务名称'),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _url,
                  enabled: !_busy && !_loading,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://example.com/v1',
                  ),
                  validator: (value) {
                    final uri = Uri.tryParse(value?.trim() ?? '');
                    return uri == null ||
                            !['http', 'https'].contains(uri.scheme) ||
                            uri.host.isEmpty ||
                            uri.userInfo.isNotEmpty ||
                            uri.hasQuery ||
                            uri.hasFragment
                        ? '请输入不含密钥的完整服务基础地址'
                        : null;
                  },
                  onChanged: (value) {
                    if (widget.profile != null &&
                        Uri.tryParse(value)?.host !=
                            Uri.tryParse(widget.profile!.baseUrl)?.host) {
                      _key.clear();
                    }
                  },
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  initialValue: _authMode,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '认证方式'),
                  items: const [
                    DropdownMenuItem(value: 'apiKey', child: Text('API Key')),
                    DropdownMenuItem(
                      value: 'none',
                      child: Text('无需认证（本地 / 自行管理的服务）'),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (mode) => setState(() => _authMode = mode!),
                ),
                TextField(
                  controller: _key,
                  enabled: !_busy && !_loading && _authMode != 'none',
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '显示密钥' : '隐藏密钥',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<LlmApiFormat>(
                  initialValue: _format,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '接口协议'),
                  items: [
                    for (final format in LlmApiFormat.values)
                      DropdownMenuItem(
                        value: format,
                        child: Text(format.label),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _format = value!),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _busy || _loading ? null : _scan,
                  icon: const Icon(Icons.radar),
                  label: Text(_busy ? '正在处理…' : '扫描可用模型'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _models,
                  enabled: !_busy,
                  minLines: 4,
                  maxLines: 12,
                  decoration: const InputDecoration(
                    labelText: '模型 ID',
                    hintText: '每行一个；扫描后也可以增删',
                    alignLabelWithHint: true,
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy || _loading ? null : _save,
                  child: const Text('保存服务'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
