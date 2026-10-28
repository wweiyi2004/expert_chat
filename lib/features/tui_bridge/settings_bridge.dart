import 'dart:async';
import '../../platform/browser.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/providers.dart';
import '../../data/gateway_config.dart';
import '../../data/media_api_config.dart';
import '../../data/provider_profile.dart';
import '../../data/subscription_catalog.dart';
import '../../domain/llm/auth/kimi_code_auth.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/llm/model_discovery.dart';
import '../../domain/llm/llm_endpoint.dart';
import '../../domain/llm/subscription_usage.dart';
import '../../state/model_service_credentials.dart'
    show chatGptAuthProvider, kimiCodeAuthProvider;
import '../../state/settings_controller.dart';
import 'protocol.dart';

part 'settings_login.dart';

class TuiSettingsBridge {
  final _loginJobs = <String, _LoginJob>{};
  TuiSettingsBridge(this.container, {required this.rememberSecrets});
  final ProviderContainer container;
  final void Function(Iterable<String>) rememberSecrets;
  static const methods = [
    'provider.login.list',
    'provider.login.account',
    'provider.login.usage',
    'provider.login.start',
    'provider.login.status',
    'provider.login.cancel',
    'provider.login.console',
    'settings.get',
    'asr.save',
    'provider.save',
    'provider.remove',
    'provider.scan',
    'provider.enable',
    'mcp.save',
    'mcp.remove',
    'mcp.scan',
    'mcp.enable',
  ];
  SettingsState get settings =>
      container.read(settingsControllerProvider).requireValue;
  SettingsController get controller =>
      container.read(settingsControllerProvider.notifier);
  ProviderProfile profile(String id) =>
      settings.profiles.where((p) => p.id == id).firstOrNull ??
      (throw const BridgeFailure('not_found', '提供商不存在'));
  CustomMcpServer server(String id) =>
      settings.gateway.customMcpServers.where((p) => p.id == id).firstOrNull ??
      (throw const BridgeFailure('not_found', 'MCP 服务不存在'));
  void confirmed(Map<String, dynamic> p) {
    if (p['confirmed'] != true) {
      throw const BridgeFailure('confirmation_required', '此操作需要独立确认');
    }
  }

  List<String> strings(Object? raw, String field) {
    if (raw is! List || raw.any((v) => v is! String)) {
      throw BridgeFailure('invalid_params', '$field 必须是字符串数组');
    }
    return field == 'args'
        ? List<String>.from(raw)
        : raw
              .cast<String>()
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toSet()
              .toList();
  }

  Map<String, String> secrets(Object? raw, String field) {
    if (raw is! Map ||
        raw.entries.any((e) => e.key is! String || e.value is! String)) {
      throw BridgeFailure('invalid_params', '$field 必须是字符串键值对象');
    }
    final value = Map<String, String>.from(raw);
    if (value.length > 64 ||
        value.entries.any(
          (e) =>
              e.key.contains(RegExp(r'[\r\n\x00]')) ||
              e.value.contains(
                field == 'headers' ? RegExp(r'[\r\n\x00]') : RegExp(r'[\x00]'),
              ),
        )) {
      throw BridgeFailure('invalid_params', '$field 含无效控制字符或过多条目');
    }
    rememberSecrets(value.values);
    return value;
  }

  Map<String, Object?> providerView(ProviderProfile p, bool hasKey) => {
    'id': p.id,
    'name': p.name,
    'api_format': p.apiFormat.wire,
    'auth_mode': p.authMode,
    'base_url': p.baseUrl,
    'models': p.models,
    'chat_model': p.chatModel,
    'reasoner_model': p.reasonerModel,
    'enabled': p.enabled,
    'has_key': hasKey,
  };
  Map<String, Object?> mcpView(CustomMcpServer s) => {
    'id': s.id,
    'name': s.name,
    'transport': s.localProcess == null ? 'http' : 'stdio',
    'command': s.localProcess?.command ?? '',
    'args': s.localProcess?.arguments ?? <String>[],
    'working_directory': s.localProcess?.workingDirectory ?? '',
    'env_keys':
        settings.customMcpEnvironments[s.id]?.keys.toList() ?? <String>[],
    'base_url': s.baseUrl,
    'header_keys': settings.customMcpHeaders[s.id]?.keys.toList() ?? <String>[],
    'enabled': s.enabled,
    'has_token': (settings.customMcpTokens[s.id] ?? '').isNotEmpty,
    'tools_count': s.tools.length,
    'tools': [
      for (final tool in s.tools)
        {'name': tool.name, 'description': tool.description},
    ],
    'last_error': s.lastError,
  };
  Future<Map<String, Object?>> view() async {
    final providers = <Map<String, Object?>>[];
    for (final p in settings.profiles) {
      final account = await _loginAccountEntry(p);
      providers.add({
        ...providerView(p, account['has_key'] == true),
        'account_label': account['account_label'],
        'account_status': account['status'],
        'account_status_label': account['status_label'],
      });
    }
    return {
      'providers': providers,
      'mcp': [for (final s in settings.gateway.customMcpServers) mcpView(s)],
      'asr': {
        'base_url': settings.asrApi.baseUrl,
        'model': settings.asrApi.model,
        'enabled': settings.asrEnabled,
        'has_key': settings.asrApiKey.isNotEmpty,
        'protocol': settings.asrApi.model.toLowerCase().contains('mimo')
            ? 'mimo_chat_audio'
            : 'openai_audio_transcriptions',
      },
      'active_profile_id': settings.activeProfileId,
      'schema': {
        'api_formats': LlmApiFormat.values.map((f) => f.wire).toList(),
        'auth_modes': ['apiKey', 'none'],
        'mcp_transports': ['stdio', 'http'],
        'attachment_limits': {
          'count': 8,
          'file_bytes': 10 * 1024 * 1024,
          'image_bytes': 5 * 1024 * 1024,
          'audio_bytes': 25 * 1024 * 1024,
          'video_bytes': 100 * 1024 * 1024,
        },
      },
    };
  }

  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, dynamic> p,
  ) async {
    await container.read(settingsControllerProvider.future);
    if (p.containsKey('enabled') && p['enabled'] is! bool) {
      throw const BridgeFailure('invalid_params', 'enabled 必须为布尔值');
    }
    if (method.startsWith('provider.login.')) return login(method, p);
    if (method == 'settings.get') return view();
    if (method == 'asr.save') {
      final base = requiredString(p, 'base_url'),
          model = requiredString(p, 'model');
      final uri = Uri.tryParse(base);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const BridgeFailure(
          'invalid_params',
          'ASR Base URL 必须为无内嵌凭据的 HTTP(S) 地址',
        );
      }
      final supplied = p['api_key'] as String?;
      final key = p['clear_key'] == true
          ? ''
          : supplied == null || supplied.isEmpty
          ? settings.asrApiKey
          : supplied;
      rememberSecrets([key]);
      await controller.setMediaApiConfig(
        MediaApiKind.asr,
        settings.asrApi.copyWith(
          baseUrl: base,
          model: model,
          apiFormat: LlmApiFormat.openAiCompatible,
        ),
      );
      if (p['clear_key'] == true || supplied?.isNotEmpty == true) {
        await controller.setMediaApiKey(MediaApiKind.asr, key);
      }
      if (p.containsKey('enabled')) {
        await controller.setAsrEnabled(p['enabled'] == true);
      }
      return {'accepted': true, ...await view()};
    }
    if (method.startsWith('provider.')) {
      if (method == 'provider.remove') {
        confirmed(p);
        profile(requiredString(p, 'id'));
        for (final job in _loginJobs.values.where(
          (j) => j.profileId == p['id'] && !j.done,
        )) {
          job.token.cancel('来源已移除');
        }
        await controller.deleteProfile(p['id'] as String);
        return {'accepted': true, ...await view()};
      }
      if (method == 'provider.scan') {
        final old = profile(requiredString(p, 'id'));
        final credentials = await controller.readCurrentProfileCredentials(
          old.id,
        );
        if (old.authMode == 'chatgpt' &&
            old.baseUrl.replaceFirst(RegExp(r'/+$'), '') !=
                'https://api.openai.com/v1') {
          throw const BridgeFailure('invalid_params', 'GPT 订阅凭据只能发送到官方服务');
        }
        if (old.authMode == 'kimiCode' && !KimiCodeAuth.accepts(old.baseUrl)) {
          throw const BridgeFailure(
            'invalid_params',
            'Kimi 登录凭据仅用于官方 Coding 服务',
          );
        }
        final scanKey = old.authMode == 'chatgpt'
            ? await container.read(chatGptAuthProvider).accessToken(old.id)
            : old.authMode == 'kimiCode'
            ? await container.read(kimiCodeAuthProvider).accessToken(old.id)
            : credentials.apiKey;
        rememberSecrets([scanKey]);
        final discovery = ModelDiscovery();
        late final List<String> models;
        try {
          models = await discovery.scan(
            settings.config.copyWith(
              profileId: old.id,
              baseUrl: old.baseUrl,
              apiKey: scanKey,
              model: old.chatModel,
              apiFormat: old.apiFormat,
              authMode: old.authMode,
            ),
            CancelToken(),
          );
        } catch (error) {
          throw BridgeFailure(
            'provider_scan_failed',
            describeModelDiscoveryError(error),
          );
        }
        final current = await controller.readCurrentProfileCredentials(old.id);
        if (current.profile.toJson().toString() != old.toJson().toString() ||
            current.apiKey != credentials.apiKey) {
          throw const BridgeFailure('conflict', '扫描期间提供商配置已改变，请重新获取模型');
        }
        await controller.saveModelService(
          old.copyWith(
            baseUrl: LlmEndpoint.base(old.baseUrl),
            models: models,
            modelLimits: discovery.limits,
            chatModel: models.contains(old.chatModel)
                ? old.chatModel
                : models.first,
            reasonerModel: models.contains(old.reasonerModel)
                ? old.reasonerModel
                : models.first,
          ),
          credentials.apiKey,
        );
        return {
          'models': models,
          'model_count': models.length,
          'complete': true,
          ...await view(),
        };
      }
      final id = p['id'] as String?;
      final old = id == null ? null : profile(id);
      if (method == 'provider.enable') {
        final key = (await controller.readCurrentProfileCredentials(
          old?.id ?? requiredString(p, 'id'),
        )).apiKey;
        await controller.saveModelService(
          old!.copyWith(enabled: p['enabled'] == true),
          key,
        );
        return {'accepted': true, ...await view()};
      }
      final name = requiredString(p, 'name'),
          base = requiredString(p, 'base_url');
      final uri = Uri.tryParse(base);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const BridgeFailure(
          'invalid_params',
          'Base URL 必须是无内嵌凭据的 HTTP(S) 地址',
        );
      }
      final format =
          p['api_format'] as String? ?? old?.apiFormat.wire ?? 'auto';
      if (!LlmApiFormat.values.any((f) => f.wire == format)) {
        throw const BridgeFailure('invalid_params', '不支持的模型协议');
      }
      final models = strings(p['models'] ?? old?.models ?? [], 'models');
      final chat =
          p['chat_model'] as String? ??
          old?.chatModel ??
          models.firstOrNull ??
          '';
      if (chat.isNotEmpty && !models.contains(chat)) models.add(chat);
      final auth = p['auth_mode'] as String? ?? old?.authMode ?? 'apiKey';
      if (!['apiKey', 'none'].contains(auth) && auth != old?.authMode) {
        throw const BridgeFailure('unsupported', '订阅账号请通过订阅服务入口授权');
      }
      if (auth == 'kimiCode' && !KimiCodeAuth.accepts(base)) {
        throw const BridgeFailure('invalid_params', 'Kimi 授权来源不能改为其他接口地址');
      }
      final suppliedKey = p['api_key'] as String?;
      final key = p['clear_key'] == true
          ? ''
          : suppliedKey?.isNotEmpty == true
          ? suppliedKey!
          : (old == null
                ? ''
                : (await controller.readCurrentProfileCredentials(
                    old.id,
                  )).apiKey);
      rememberSecrets([key]);
      final next = ProviderProfile(
        id: old?.id,
        name: name,
        baseUrl: LlmEndpoint.base(base),
        apiFormat: LlmApiFormat.fromWire(format),
        models: models,
        chatModel: chat,
        reasonerModel:
            p['reasoner_model'] as String? ?? old?.reasonerModel ?? chat,
        authMode: auth,
        enabled: p['enabled'] as bool? ?? old?.enabled ?? true,
        modelLimits: old?.modelLimits ?? const {},
      );
      await controller.saveModelService(next, key);
      return {'accepted': true, 'id': next.id, ...await view()};
    }
    if (method == 'mcp.remove') {
      confirmed(p);
      server(requiredString(p, 'id'));
      await controller.deleteCustomMcpServer(p['id'] as String);
      return {'accepted': true, ...await view()};
    }
    if (method == 'mcp.enable') {
      final id = requiredString(p, 'id');
      server(id);
      await controller.setCustomMcpEnabled(id, p['enabled'] == true);
      return {'accepted': true, ...await view()};
    }
    if (method == 'mcp.scan') {
      confirmed(p);
      final s = server(requiredString(p, 'id'));
      if (!s.enabled) throw const BridgeFailure('conflict', '请先启用此 MCP 服务');
      try {
        final capabilities = await container
            .read(gatewayClientProvider)
            .discover(connection: settings.connectionForCustom(s));
        await controller.setCustomMcpDiscovered(
          s.id,
          tools: capabilities.tools,
          serverVersion: capabilities.gatewayVersion,
        );
      } catch (_) {
        await controller.setCustomMcpError(s.id, '工具发现失败，请核对命令、参数、地址和认证配置');
        rethrow;
      }
      return {
        'accepted': true,
        'tools': [
          for (final t in server(s.id).tools)
            {'name': t.name, 'description': t.description},
        ],
        ...await view(),
      };
    }
    final old = p['id'] == null ? null : server(requiredString(p, 'id'));
    final id = old?.id ?? const Uuid().v4();
    final name = requiredString(p, 'name');
    final transport =
        p['transport'] as String? ??
        (old?.localProcess == null ? 'http' : 'stdio');
    if (!['http', 'stdio'].contains(transport)) {
      throw const BridgeFailure('invalid_params', '不支持的 MCP 传输');
    }
    final base = transport == 'http' ? requiredString(p, 'base_url') : '';
    if (transport == 'http') {
      final uri = Uri.tryParse(base);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const BridgeFailure(
          'invalid_params',
          'MCP 地址必须是无内嵌凭据的 HTTP(S) 地址',
        );
      }
    }
    final process = transport == 'stdio'
        ? McpProcessConfig(
            command: requiredString(p, 'command'),
            arguments: strings(
              p['args'] ?? old?.localProcess?.arguments ?? [],
              'args',
            ),
            workingDirectory:
                p['working_directory'] as String? ??
                old?.localProcess?.workingDirectory ??
                '',
          )
        : null;
    final oldEnv =
        settings.customMcpEnvironments[id] ?? const <String, String>{};
    final oldHeaders =
        settings.customMcpHeaders[id] ?? const <String, String>{};
    final env = p.containsKey('env') ? secrets(p['env'], 'env') : null;
    final headers = p.containsKey('headers')
        ? secrets(p['headers'], 'headers')
        : null;
    if (env != null &&
        env.keys.any((k) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(k))) {
      throw const BridgeFailure('invalid_params', '环境变量名无效');
    }
    await controller.setCustomMcpSecrets(
      id,
      environment: env,
      headers: headers,
    );
    try {
      if (old == null) {
        await controller.addCustomMcpServer(
          id: id,
          name: name,
          baseUrl: base,
          localProcess: process,
        );
      } else {
        await controller.updateCustomMcpServer(
          id: id,
          name: name,
          baseUrl: base,
          localProcess: process,
          computerUse: old.computerUse,
          allowForeground: old.allowForeground,
        );
      }
      if (p['clear_token'] == true ||
          (p['token'] as String?)?.isNotEmpty == true) {
        final token = p['clear_token'] == true ? '' : p['token'] as String;
        rememberSecrets([token]);
        await controller.setCustomMcpToken(id, token);
      }
      if (p.containsKey('enabled')) {
        await controller.setCustomMcpEnabled(id, p['enabled'] == true);
      }
    } catch (_) {
      await controller.setCustomMcpSecrets(
        id,
        environment: oldEnv,
        headers: oldHeaders,
      );
      rethrow;
    }
    return {'accepted': true, 'id': id, ...await view()};
  }
}
