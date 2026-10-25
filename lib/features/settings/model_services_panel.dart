import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../../data/provider_profile.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/llm/model_discovery.dart';
import '../../domain/llm/auth/chatgpt_auth_errors.dart';
import '../../state/model_service_credentials.dart';
import '../../state/model_service_routing.dart';
import '../../state/settings_controller.dart';
import 'model_service_editor.dart';
import '../../core/prototype_widgets.dart';
import 'widgets/model_route_diagnostics_panel.dart';
import 'widgets/model_route_groups_panel.dart';
import 'widgets/magpie_companion_panel.dart';

class ModelServicesPanel extends ConsumerStatefulWidget {
  const ModelServicesPanel({
    super.key,
    this.embedded = false,
    this.beforeSubscriptions,
  });
  final Widget? beforeSubscriptions;
  final bool embedded;
  @override
  ConsumerState<ModelServicesPanel> createState() => _ModelServicesPanelState();
}

class _ModelServicesPanelState extends ConsumerState<ModelServicesPanel> {
  String? _selected, _error;
  String _loginStage = '等待授权';
  bool _busy = false;
  CancelToken? _login;
  @override
  void dispose() {
    _login?.cancel();
    super.dispose();
  }

  Future<void> _edit([ProviderProfile? profile, ProviderPreset? preset]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelServiceEditor(profile: profile, preset: preset),
      ),
    );
  }

  Future<void> _use(String model) async {
    final settings = ref.read(settingsControllerProvider).value!;
    final services = servicesForModel(
      model,
      settings.profiles,
      ref.read(modelServiceRoutingProvider),
    );
    if (services.isEmpty) return;
    try {
      await ref
          .read(settingsControllerProvider.notifier)
          .selectProfile(services.first.id);
      await ref
          .read(settingsControllerProvider.notifier)
          .apply(selectedModel: model);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _signIn([ProviderProfile? existing]) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final token = _login = CancelToken();
    final id = existing?.id ?? const Uuid().v4();
    var authorized = false;
    try {
      final auth = ref.read(chatGptAuthProvider);
      final account = await auth.signIn(
        id,
        token,
        onStage: (stage) {
          if (mounted) setState(() => _loginStage = stage);
        },
      );
      authorized = true;
      if (mounted) setState(() => _loginStage = '读取账号可用模型');
      await ref
          .read(settingsControllerProvider.notifier)
          .saveModelService(
            ProviderProfile(
              id: id,
              name: 'ChatGPT · ${account['email'] ?? '订阅账号'}',
              baseUrl: 'https://api.openai.com/v1',
              chatModel: existing?.chatModel ?? '',
              reasonerModel: existing?.reasonerModel ?? '',
              models: existing?.models ?? [],
              apiFormat: LlmApiFormat.openAiResponses,
              authMode: 'chatgpt',
            ),
            '',
          );
      final discovery = ModelDiscovery();
      final models = await discovery.scan(
        LlmConfig(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: account['access_token'] as String,
          model: '',
          apiFormat: LlmApiFormat.openAiResponses,
          authMode: 'chatgpt',
        ),
        token,
      );
      final profile = ProviderProfile(
        id: id,
        name: 'ChatGPT · ${account['email'] ?? '订阅账号'}',
        baseUrl: 'https://api.openai.com/v1',
        chatModel: models.first,
        reasonerModel: models.first,
        models: models,
        modelLimits: {...discovery.limits},
        apiFormat: LlmApiFormat.openAiResponses,
        authMode: 'chatgpt',
      );
      await ref
          .read(settingsControllerProvider.notifier)
          .saveModelService(profile, '');
      ref.invalidate(_chatGptAccountRecordProvider(id));
      if (mounted) setState(() => _selected = models.first);
    } catch (error) {
      if (mounted && !token.isCancelled) {
        setState(
          () => _error =
              '${authorized ? '账号已授权，模型扫描未完成' : _loginStage}：${describeChatGptAuthFailure(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final preset = await showModalBottomSheet<ProviderPreset>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ServicePresetPicker(),
    );
    if (mounted && preset != null) await _edit(null, preset);
  }

  Future<void> _remove(ProviderProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('删除 ${profile.name}？'),
        content: const Text('将移除此服务配置；会话记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final revoked =
          profile.authMode != 'chatgpt' ||
          await ref.read(chatGptAuthProvider).signOut(profile.id);
      await ref
          .read(settingsControllerProvider.notifier)
          .deleteProfile(profile.id);
      if (!revoked && mounted) {
        setState(() => _error = '本机已退出；远程撤销未确认，可在 ChatGPT 设置中断开此应用。');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider).value;
    if (settings == null) return const LinearProgressIndicator();
    final priorities = ref.watch(modelServiceRoutingProvider);
    final models = serviceModelCatalog(settings.profiles);
    final selected = models.contains(_selected)
        ? _selected!
        : models.contains(settings.model)
        ? settings.model
        : models.firstOrNull;
    final services = selected == null
        ? <ProviderProfile>[]
        : servicesForModel(selected, settings.profiles, priorities);
    return _serviceSettingsPanels(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded)
          Text('模型与服务', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          '选择模型，管理哪些服务提供它，并拖动调整使用顺序。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (selected != null)
          DropdownMenu<String>(
            key: ValueKey('models-$selected-${models.length}'),
            initialSelection: selected,
            enableFilter: true,
            enableSearch: true,
            expandedInsets: EdgeInsets.zero,
            label: const Text('模型'),
            textStyle: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontSize: 13),
            inputDecorationTheme: Theme.of(context).inputDecorationTheme
                .copyWith(
                  isDense: true,
                  constraints: const BoxConstraints(
                    minHeight: 34,
                    maxHeight: 40,
                  ),
                  floatingLabelBehavior: FloatingLabelBehavior.never,
                ),
            dropdownMenuEntries: [
              for (final model in models)
                DropdownMenuEntry(value: model, label: model),
            ],
            onSelected: (model) => setState(() => _selected = model),
          ),
        const SizedBox(height: 12),
        if (selected != null)
          Align(
            alignment: Alignment.centerLeft,
            child: PrototypeButton(
              small: true,
              variant: PrototypeButtonVariant.ghost,
              onPressed: () => _use(selected),
              icon: Icons.check_circle_outline,
              label:
                  settings.model == selected &&
                      settings.activeProfileId == services.firstOrNull?.id
                  ? '当前使用此模型'
                  : '使用此模型',
            ),
          ),
        const SizedBox(height: 16),
        Text(
          '提供此模型的服务 · ${services.length}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        if (services.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('添加服务并扫描模型后，会在这里列出。'),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: services.length,
            onReorderItem: (oldIndex, newIndex) async {
              final ids = services.map((p) => p.id).toList();
              ids.insert(newIndex, ids.removeAt(oldIndex));
              try {
                await ref
                    .read(modelServiceRoutingProvider.notifier)
                    .reorder(selected!, ids);
              } catch (error) {
                if (mounted) setState(() => _error = '$error');
              }
            },
            itemBuilder: (context, index) {
              final service = services[index];
              return Card(
                key: ValueKey(service.id),
                child: ListTile(
                  leading: Text(
                    '${index + 1}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  title: Text(service.name),
                  subtitle: Text(
                    '${service.authMode == 'chatgpt' ? '订阅登录 · ' : ''}${service.baseUrl}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            service.authMode == 'chatgpt'
                                ? _signIn(service)
                                : _edit(service);
                          }
                          if (value == 'remove') _remove(service);
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(
                              service.authMode == 'chatgpt'
                                  ? '重新登录并扫描'
                                  : '编辑与扫描模型',
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('删除服务'),
                          ),
                        ],
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: 10),
        Text(
          '仅在同一模型的渠道之间按优先级故障转移；收到内容后固定任务渠道。切换模型需要单独选择。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        ModelRouteDiagnosticsPanel(profiles: settings.profiles),
        const ModelRouteGroupsPanel(),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            PrototypeButton(
              small: true,
              onPressed: _busy ? null : _add,
              icon: Icons.add,
              label: '预设服务',
            ),
            PrototypeButton(
              small: true,
              onPressed: _busy ? null : () => _edit(),
              icon: Icons.link,
              label: '自定义 Base URL',
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text('订阅与账号', style: Theme.of(context).textTheme.titleMedium),
        const MagpieCompanionPanel(),
        const SizedBox(height: 8),
        Text('Codex / ChatGPT', style: Theme.of(context).textTheme.titleSmall),
        const Text('通过系统浏览器授权订阅账号；登录凭据与 API Key 分开管理。'),
        for (final profile in settings.profiles.where(
          (p) => p.authMode == 'chatgpt',
        ))
          _ChatGptAccountCard(
            profile: profile,
            busy: _busy,
            onSignIn: () => _signIn(profile),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _signIn(),
            icon: const Icon(Icons.person_add_alt),
            label: Text(_busy ? '$_loginStage…' : '添加 ChatGPT 账号'),
          ),
        ),
        if (_busy)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _login?.cancel(),
              child: const Text('取消登录'),
            ),
          ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.code),
            title: const Text('OpenCode Console / Go'),
            subtitle: const Text('登录官方控制台获取 Key，再选择对应预设并扫描模型'),
            trailing: IconButton(
              tooltip: '登录 OpenCode',
              onPressed: () => launchUrl(
                Uri.parse('https://opencode.ai/auth'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
            ),
          ),
        ),
        ExpansionTile(
          title: const Text('其他订阅与 Coding Plan'),
          children: [
            const ListTile(
              title: Text('GLM / Kimi / MiniMax / 阿里云 Coding Plan'),
              subtitle: Text('使用对应套餐的专用 Base URL 与 Key，在预设服务中添加。'),
            ),
            ListTile(
              title: const Text('GitHub Copilot'),
              subtitle: const Text(
                '官方 SDK 登录需要应用的 GitHub OAuth 配置；不与 GitHub Models API 混用。',
              ),
              trailing: IconButton(
                tooltip: '官方接入说明',
                onPressed: () => launchUrl(
                  Uri.parse(
                    'https://docs.github.com/en/copilot/how-tos/copilot-sdk/setup/github-oauth',
                  ),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new),
              ),
            ),
            ListTile(
              title: const Text('Claude / Gemini 订阅'),
              subtitle: const Text(
                '原生订阅登录与通用 API 是不同接入方式。目前可添加官方 API 服务；订阅 CLI 桥接尚未接入。',
              ),
              trailing: IconButton(
                tooltip: '添加 API 服务',
                onPressed: _add,
                icon: const Icon(Icons.add),
              ),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 14),
        ExpansionTile(
          title: Text('管理全部服务（${settings.profiles.length}）'),
          children: [
            for (final service in settings.profiles)
              ListTile(
                title: Text(service.name),
                subtitle: Text('${service.models.length} 个模型'),
                onTap: () => service.authMode == 'chatgpt'
                    ? _signIn(service)
                    : _edit(service),
              ),
          ],
        ),
      ],
    );
  }

  Widget _serviceSettingsPanels({
    required CrossAxisAlignment crossAxisAlignment,
    required List<Widget> children,
  }) {
    if (!widget.embedded) {
      return Column(crossAxisAlignment: crossAxisAlignment, children: children);
    }
    final parts = <String, List<Widget>>{
      '模型服务': [],
      '默认模型': [],
      '路由与故障转移': [],
      '订阅与账号': [],
    };
    var current = '默认模型';
    for (final child in children) {
      if (child is SizedBox && child.child == null && child.height != null) {
        continue;
      }
      if (child is Text && child.data == '订阅与账号') {
        current = '订阅与账号';
        continue;
      }
      if (child is Text && (child.data?.startsWith('提供此模型的服务') ?? false)) {
        current = '模型服务';
      }
      if (child is ModelRouteDiagnosticsPanel ||
          child is ModelRouteGroupsPanel) {
        parts['路由与故障转移']!.add(child);
        continue;
      }
      if (child is Wrap &&
          child.children.any(
            (w) => w is OutlinedButton || w is PrototypeButton,
          )) {
        parts['模型服务']!.add(child);
        continue;
      }
      parts[current]!.add(child);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final part in parts.entries)
          if (part.value.isNotEmpty) ...[
            if (part.key == '订阅与账号' && widget.beforeSubscriptions != null) ...[
              widget.beforeSubscriptions!,
              const SizedBox(height: 16),
            ],
            PrototypePanel(
              title: part.key,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < part.value.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    part.value[i],
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
      ],
    );
  }
}

class _ServicePresetPicker extends StatefulWidget {
  const _ServicePresetPicker();
  @override
  State<_ServicePresetPicker> createState() => _ServicePresetPickerState();
}

class _ServicePresetPickerState extends State<_ServicePresetPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索提供商或套餐',
              ),
              onChanged: (value) => setState(() => query = value),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final preset in ProviderPreset.presets.where(
                  (p) => p.matchesQuery(query),
                ))
                  ListTile(
                    title: Text(preset.name),
                    subtitle: Text(
                      preset.hint.isEmpty ? preset.baseUrl : preset.hint,
                    ),
                    onTap: () => Navigator.pop(context, preset),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

final _chatGptAccountRecordProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, id) => ref.watch(chatGptAuthProvider).saved(id),
    );

class _ChatGptAccountCard extends ConsumerStatefulWidget {
  const _ChatGptAccountCard({
    required this.profile,
    required this.busy,
    required this.onSignIn,
  });
  final ProviderProfile profile;
  final bool busy;
  final VoidCallback onSignIn;
  @override
  ConsumerState<_ChatGptAccountCard> createState() =>
      _ChatGptAccountCardState();
}

class _ChatGptAccountCardState extends ConsumerState<_ChatGptAccountCard> {
  bool _refreshing = false;
  String? _status;
  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _status = null;
    });
    try {
      await ref.read(chatGptAuthProvider).accessToken(widget.profile.id);
      ref.invalidate(_chatGptAccountRecordProvider(widget.profile.id));
      if (mounted) setState(() => _status = '登录凭据有效');
    } catch (error) {
      if (mounted) setState(() => _status = describeChatGptAuthFailure(error));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(_chatGptAccountRecordProvider(widget.profile.id));
    final saved = record.value;
    final signedIn =
        saved?['access_token'] is String &&
        (saved!['access_token'] as String).isNotEmpty;
    final email = saved?['email']?.toString();
    final expiry = DateTime.tryParse(saved?['expires_at']?.toString() ?? '');
    final expired = expiry != null && expiry.isBefore(DateTime.now());
    return Card(
      key: ValueKey('chatgpt-account-${widget.profile.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              email?.isNotEmpty == true
                  ? 'ChatGPT · $email'
                  : widget.profile.name,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              record.isLoading
                  ? '读取登录状态…'
                  : record.hasError
                  ? '无法读取登录状态'
                  : signedIn
                  ? '${expired ? '登录凭据待刷新' : '已登录'} · ${widget.profile.models.length} 个已扫描模型'
                  : '未登录或登录凭据已移除',
            ),
            if (_status != null) Text(_status!),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (signedIn)
                  OutlinedButton.icon(
                    onPressed: _refreshing || widget.busy ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                    label: Text(_refreshing ? '刷新中…' : '刷新登录状态'),
                  ),
                OutlinedButton(
                  onPressed: widget.busy ? null : widget.onSignIn,
                  child: Text(signedIn ? '重新授权并扫描模型' : 'Continue with ChatGPT'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
