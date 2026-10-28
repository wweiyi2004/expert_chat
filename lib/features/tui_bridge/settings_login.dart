part of 'settings_bridge.dart';

final _subscriptionUsage = SubscriptionUsageService();

class _LoginJob {
  _LoginJob(this.id, this.scope, this.profileId);
  final String id, scope, profileId;
  final token = CancelToken();
  String stage = '准备登录';
  bool done = false, success = false;
  int models = 0;
  String? verificationUrl, userCode;
  Map<String, Object?> view() => {
    'job_id': id,
    'profile_id': profileId,
    'stage': stage,
    'done': done,
    'success': success,
    'model_count': models,
    if (verificationUrl != null) 'verification_url': verificationUrl,
    if (userCode != null) 'user_code': userCode,
  };
}

extension TuiProviderLogin on TuiSettingsBridge {
  String _accountText(Object? value) =>
      value is String ? value.trim().replaceAll(RegExp(r'[\r\n\t]+'), ' ') : '';

  DateTime? _accountExpiry(Object? value) {
    if (value is num) {
      final millis = value < 100000000000 ? value * 1000 : value;
      return DateTime.fromMillisecondsSinceEpoch(millis.toInt(), isUtc: true);
    }
    return value is String ? DateTime.tryParse(value) : null;
  }

  String _accountEndpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return value.trim();
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    for (final suffix in ['/chat/completions', '/responses', '/messages']) {
      if (path.endsWith(suffix)) {
        path = path.substring(0, path.length - suffix.length);
        break;
      }
    }
    return uri.replace(path: path).removeFragment().toString();
  }

  /// Read saved credentials locally, but expose only account display metadata
  /// and presence/status flags. Listing accounts never refreshes or calls APIs.
  Future<Map<String, Object?>> _loginAccountEntry(ProviderProfile p) async {
    final endpoint = _accountEndpoint(p.baseUrl);
    final subscription = SubscriptionEntry.entries
        .where((entry) => _accountEndpoint(entry.baseUrl) == endpoint)
        .firstOrNull;
    final preset = ProviderPreset.presets
        .where((entry) => _accountEndpoint(entry.baseUrl) == endpoint)
        .firstOrNull;
    final oauth = p.authMode == 'chatgpt' || p.authMode == 'kimiCode';
    final brand = p.authMode == 'chatgpt'
        ? 'ChatGPT'
        : p.authMode == 'kimiCode'
        ? 'Kimi Code'
        : subscription?.name ??
              preset?.name ??
              Uri.tryParse(p.baseUrl)?.host ??
              '自定义来源';
    var label = p.name.trim().isEmpty ? brand : p.name.trim();
    var labelSource = 'source_name';
    var status = 'missing_key';
    var statusLabel = '未配置 Key';
    var hasCredential = false;
    var credentialReady = false;
    var plan = '';
    try {
      if (oauth) {
        final account = p.authMode == 'chatgpt'
            ? await container.read(chatGptAuthProvider).saved(p.id)
            : await container.read(kimiCodeAuthProvider).saved(p.id);
        if (account == null) {
          status = 'signed_out';
          statusLabel = '未登录';
        } else {
          rememberSecrets([
            for (final key in ['access_token', 'refresh_token', 'id_token'])
              if (account[key] is String) account[key] as String,
          ]);
          final identities = p.authMode == 'chatgpt'
              ? [account['email'], account['name']]
              : [account['name'], account['email'], account['nickname']];
          final accountLabel = identities
              .map(_accountText)
              .where(
                (name) =>
                    name.isNotEmpty && name != 'Kimi Code' && name != '订阅账号',
              )
              .firstOrNull;
          if (accountLabel != null) {
            label = accountLabel;
            labelSource = 'account';
          }
          plan = _accountText(account['plan']);
          final hasAccess = _accountText(account['access_token']).isNotEmpty;
          final hasRefresh = _accountText(account['refresh_token']).isNotEmpty;
          final expiry = _accountExpiry(account['expires_at']);
          final descriptorReady =
              p.authMode != 'chatgpt' ||
              _accountText(account['client_id']).isNotEmpty;
          hasCredential = hasAccess || hasRefresh;
          if (hasAccess &&
              descriptorReady &&
              expiry != null &&
              expiry.isAfter(DateTime.now())) {
            status = 'authorized';
            statusLabel = '已授权';
            credentialReady = true;
          } else if (hasRefresh &&
              descriptorReady &&
              (p.authMode == 'kimiCode' || expiry != null)) {
            status = 'refresh_pending';
            statusLabel = '授权待刷新';
            credentialReady = true;
          } else {
            status = 'reauth_required';
            statusLabel = '需要重新登录';
          }
        }
      } else if (p.authMode == 'none') {
        status = 'no_auth';
        statusLabel = '无需 Key';
        credentialReady = true;
      } else {
        final credential = await controller.readCurrentProfileCredentials(p.id);
        rememberSecrets([credential.apiKey]);
        hasCredential = credential.apiKey.trim().isNotEmpty;
        credentialReady = hasCredential;
        if (hasCredential) {
          status = 'key_saved';
          statusLabel = 'Key 已保存';
        }
      }
    } catch (_) {
      status = 'credential_error';
      statusLabel = '凭据不可读';
    }
    final method = oauth
        ? '账号授权'
        : p.authMode == 'none'
        ? '免密来源'
        : 'API Key';
    return {
      'kind': 'account',
      'key': 'account:${p.id}',
      'profile_id': p.id,
      'name': label,
      'source_name': p.name,
      'account_label': label,
      'account_label_source': labelSource,
      'description':
          '$brand · $method · ${p.enabled ? '' : '已禁用 · '}$statusLabel',
      'provider': oauth ? p.authMode : subscription?.id ?? 'custom',
      'provider_label': brand,
      'auth_mode': p.authMode,
      'enabled': p.enabled,
      'has_key': hasCredential,
      'credential_ready': credentialReady,
      'status': status,
      'status_label': statusLabel,
      'can_reauthorize': oauth,
      if (plan.isNotEmpty) 'plan_label': plan,
    };
  }

  bool get loginActive => _loginJobs.values.any((j) => !j.done);
  String? _loginConsoleUrl(ProviderProfile savedProfile) {
    if (savedProfile.authMode == 'chatgpt') return 'https://chatgpt.com';
    if (savedProfile.authMode == 'kimiCode') {
      return 'https://www.kimi.com/code/console';
    }
    return SubscriptionEntry.entries
        .where(
          (entry) =>
              _accountEndpoint(entry.baseUrl) ==
              _accountEndpoint(savedProfile.baseUrl),
        )
        .firstOrNull
        ?.consoleUrl;
  }

  Future<Map<String, Object?>> _loginUsage(Map<String, dynamic> params) async {
    final savedProfile = profile(requiredString(params, 'profile_id'));
    final account = await _loginAccountEntry(savedProfile);
    final metadata = <String, Object?>{
      'profile_id': savedProfile.id,
      'account_name': account['name'],
      'plan': account['plan_label'],
      'console_url': _loginConsoleUrl(savedProfile),
    };
    if (savedProfile.authMode == 'chatgpt' ||
        savedProfile.authMode == 'kimiCode') {
      final stored = savedProfile.authMode == 'chatgpt'
          ? await container.read(chatGptAuthProvider).saved(savedProfile.id)
          : await container.read(kimiCodeAuthProvider).saved(savedProfile.id);
      final expiry = _accountExpiry(stored?['expires_at']);
      if (expiry != null) {
        metadata['credential_expires_at'] = expiry.toUtc().toIso8601String();
      }
    }
    final usage = await _subscriptionUsage.inspect(
      savedProfile,
      metadata: metadata,
      refresh: params['refresh'] == true,
      headers: savedProfile.authMode == 'kimiCode'
          ? await container.read(kimiCodeAuthProvider).headers()
          : const {},
      credential: () async {
        String key;
        if (savedProfile.authMode == 'kimiCode') {
          if (!KimiCodeAuth.accepts(savedProfile.baseUrl)) {
            throw StateError('Kimi 授权仅能用于官方 Coding 地址。');
          }
          key = await container
              .read(kimiCodeAuthProvider)
              .accessToken(savedProfile.id);
        } else {
          key = (await controller.readCurrentProfileCredentials(
            savedProfile.id,
          )).apiKey;
        }
        rememberSecrets([key]);
        return key;
      },
    );
    if (profile(savedProfile.id).toJson().toString() !=
        savedProfile.toJson().toString()) {
      throw const BridgeFailure('conflict', '账号配置已改变，请重新打开额度页面');
    }
    return {'account': account, 'usage': usage};
  }

  void releaseLogins(String scope) {
    for (final job in _loginJobs.values.where(
      (j) => j.scope == scope && !j.done,
    )) {
      job.token.cancel('登录窗口已关闭');
    }
    _loginJobs.removeWhere((_, j) => j.scope == scope && j.done);
  }

  Future<Map<String, Object?>> login(
    String method,
    Map<String, dynamic> params,
  ) async {
    final scope = requiredString(params, '_bridge_client_scope');
    if (method == 'provider.login.usage') return _loginUsage(params);
    if (method == 'provider.login.account') {
      final savedProfile = profile(requiredString(params, 'profile_id'));
      final account = await _loginAccountEntry(savedProfile);
      return {
        'account': account,
        'profile': providerView(savedProfile, account['has_key'] == true),
      };
    }
    if (method == 'provider.login.list') {
      return {
        'providers': [
          for (final savedProfile in settings.profiles)
            await _loginAccountEntry(savedProfile),
          {
            'key': 'chatgpt',
            'name': 'ChatGPT 订阅',
            'description': '浏览器授权 · 自动获取账号可用模型',
            'kind': 'oauth',
          },
          {
            'key': 'kimi',
            'name': 'Kimi Code 订阅',
            'description': '网页登录 / 套餐 Key',
            'kind': 'subscription',
            'options': [
              {
                'key': 'kimi-oauth',
                'name': '浏览器授权',
                'description': '设备码登录 · 自动刷新授权',
                'kind': 'oauth',
                'provider': 'kimiCode',
              },
              SubscriptionEntry.find('kimi-code')!.view(),
              SubscriptionEntry.find('kimi-code-global')!.view(),
            ],
          },
          for (final entry in SubscriptionEntry.entries.where(
            (e) => !e.id.startsWith('kimi-code'),
          ))
            entry.view(),
          for (final preset in ProviderPreset.presets.where(
            (p) =>
                p.name == 'OpenCode Console / Zen (OpenAI)' ||
                p.name == 'OpenCode Go (OpenAI)',
          ))
            if (preset.name != 'OpenCode Go (OpenAI)')
              {
                'key': preset.name,
                'name': preset.name,
                'description': '浏览器登录控制台取得 Key，再自动获取模型',
                'kind': 'console',
                'base_url': preset.baseUrl,
                'api_format': preset.apiFormat.wire,
              },
          {
            'key': 'custom',
            'name': '其他 API / Coding Plan',
            'description': '填写自己的 Base URL 和 Key',
            'kind': 'api',
          },
        ],
      };
    }
    if (method == 'provider.login.status' ||
        method == 'provider.login.cancel') {
      final job = _loginJobs[params['job_id']];
      if (job == null || job.scope != scope) {
        throw const BridgeFailure('not_found', '登录任务不存在或已结束，请重新 /login');
      }
      if (method == 'provider.login.cancel' && !job.done) {
        job.token.cancel('用户取消登录');
        job.stage = '正在取消登录…';
      }
      return job.view();
    }
    if (method == 'provider.login.console') {
      if (params['profile_id'] is String) {
        final url = _loginConsoleUrl(
          profile(requiredString(params, 'profile_id')),
        );
        if (url == null) return {'notice': '此自定义来源未配置官方控制台，请自行打开服务商网站。'};
        if (!await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        )) {
          return {'notice': '请在浏览器打开 $url'};
        }
        return {'notice': '已打开官方控制台'};
      }
      final requested = params['provider'] as String?;
      final entry = requested == null
          ? null
          : SubscriptionEntry.find(requested);
      if (requested != null && entry == null) {
        throw const BridgeFailure('not_found', '订阅服务不存在');
      }
      final url = entry?.consoleUrl ?? 'https://opencode.ai/auth';
      if (!await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return {'notice': '请在浏览器打开 $url，取得套餐 Key 后粘贴并保存'};
      }
      return {
        'notice': '已打开${entry?.name ?? 'OpenCode'}控制台；取得 Key 后粘贴到当前表单并保存',
      };
    }
    if (method != 'provider.login.start') {
      throw const BridgeFailure('unsupported', '未知登录操作');
    }
    final running = _loginJobs.values
        .where((j) => j.scope == scope && !j.done)
        .firstOrNull;
    if (running != null) return running.view();
    final requested = params['profile_id'] as String?;
    final old = requested == null ? null : profile(requested);
    final provider =
        params['provider'] as String? ?? old?.authMode ?? 'chatgpt';
    if (!['chatgpt', 'kimiCode'].contains(provider)) {
      throw const BridgeFailure('unsupported', '此服务请使用套餐 Key 接入');
    }
    if (old != null && old.authMode != provider) {
      throw const BridgeFailure('invalid_params', '来源的账号类型不匹配');
    }
    final job = _LoginJob(
      const Uuid().v4(),
      scope,
      old?.id ?? const Uuid().v4(),
    );
    _loginJobs.removeWhere((_, j) => j.scope == scope && j.done);
    _loginJobs[job.id] = job;
    unawaited(
      provider == 'kimiCode' ? _runKimiLogin(job, old) : _runLogin(job, old),
    );
    return job.view();
  }

  Future<void> _runKimiLogin(_LoginJob job, ProviderProfile? old) async {
    var authorized = false;
    try {
      final auth = container.read(kimiCodeAuthProvider);
      final account = await auth.signIn(
        job.profileId,
        job.token,
        onStage: (value) => job.stage = value,
        onDevice: (url, code) {
          job.verificationUrl = url;
          job.userCode = code;
        },
      );
      if (job.token.isCancelled) throw job.token.cancelError!;
      final current = settings.profiles
          .where((p) => p.id == job.profileId)
          .firstOrNull;
      if (old != null &&
          current?.toJson().toString() != old.toJson().toString()) {
        throw const BridgeFailure('conflict', '来源已改变，请重新授权');
      }
      rememberSecrets([
        account['access_token'] as String,
        account['refresh_token'] as String,
      ]);
      final profile = ProviderProfile(
        id: job.profileId,
        name: old?.name ?? 'Kimi Code · ${account['name']}',
        enabled: old?.enabled ?? true,
        baseUrl: KimiCodeAuth.baseUrl,
        apiFormat: LlmApiFormat.auto,
        authMode: 'kimiCode',
        chatModel: old?.chatModel ?? '',
        reasonerModel: old?.reasonerModel ?? '',
        models: old?.models ?? [],
        modelLimits: old?.modelLimits ?? const {},
      );
      await controller.saveModelService(profile, '');
      await auth.save(profile.id, account);
      authorized = true;
      if (job.token.isCancelled) throw job.token.cancelError!;
      job.stage = 'Kimi 已授权，正在获取账号可用模型…';
      final discovery = ModelDiscovery();
      final models = await discovery.scan(
        LlmConfig(
          baseUrl: profile.baseUrl,
          apiKey: account['access_token'] as String,
          model: '',
          authMode: 'kimiCode',
          apiFormat: LlmApiFormat.auto,
        ),
        job.token,
      );
      if (job.token.isCancelled) throw job.token.cancelError!;
      final latest = settings.profiles
          .where((p) => p.id == profile.id)
          .firstOrNull;
      if (latest?.toJson().toString() != profile.toJson().toString()) {
        throw const BridgeFailure('conflict', '来源已改变，请重新获取模型');
      }
      await controller.saveModelService(
        profile.copyWith(
          models: models,
          modelLimits: discovery.limits,
          chatModel: models.contains(profile.chatModel)
              ? profile.chatModel
              : models.first,
          reasonerModel: models.contains(profile.reasonerModel)
              ? profile.reasonerModel
              : models.first,
        ),
        '',
      );
      job.models = models.length;
      job.success = true;
      job.stage = 'Kimi Code 登录完成 · ${models.length} 个模型；/model 选择使用';
    } catch (error) {
      job.stage = job.token.isCancelled
          ? (authorized ? '已取消获取模型；账号保留，可重新扫描' : 'Kimi 登录已取消')
          : error is BridgeFailure
          ? error.message
          : error is StateError
          ? error.message
          : authorized
          ? 'Kimi 已授权，模型获取失败；可在设置中重新获取'
          : 'Kimi 授权未完成，请检查网络后重新登录';
    } finally {
      job.done = true;
    }
  }

  Future<void> _runLogin(_LoginJob job, ProviderProfile? old) async {
    var authorized = false;
    try {
      final account = await container
          .read(chatGptAuthProvider)
          .signIn(job.profileId, job.token, onStage: (s) => job.stage = s);
      authorized = true;
      rememberSecrets([
        for (final key in ['access_token', 'refresh_token', 'id_token'])
          if (account[key] is String) account[key] as String,
      ]);
      final current = settings.profiles
          .where((p) => p.id == job.profileId)
          .firstOrNull;
      if (old != null &&
          current?.toJson().toString() != old.toJson().toString()) {
        throw const BridgeFailure('conflict', '来源已改变，请重新获取模型');
      }
      // Preserve a successfully authorized account even when discovery later fails.
      final profile = ProviderProfile(
        id: job.profileId,
        name: old?.name ?? 'ChatGPT · ${account['email'] ?? '订阅账号'}',
        enabled: old?.enabled ?? true,
        baseUrl: 'https://api.openai.com/v1',
        chatModel: old?.chatModel ?? '',
        reasonerModel: old?.reasonerModel ?? '',
        models: old?.models ?? [],
        modelLimits: old?.modelLimits ?? const {},
        apiFormat: LlmApiFormat.openAiResponses,
        authMode: 'chatgpt',
      );
      await controller.saveModelService(profile, '');
      if (job.token.isCancelled) throw job.token.cancelError!;
      job.stage = '授权成功，正在完整获取账号可用模型…';
      final discovery = ModelDiscovery();
      final models = await discovery.scan(
        LlmConfig(
          baseUrl: profile.baseUrl,
          apiKey: account['access_token'] as String,
          model: '',
          profileId: profile.id,
          apiFormat: LlmApiFormat.openAiResponses,
          authMode: 'chatgpt',
        ),
        job.token,
      );
      if (job.token.isCancelled) throw job.token.cancelError!;
      final latest = settings.profiles
          .where((p) => p.id == profile.id)
          .firstOrNull;
      if (latest?.toJson().toString() != profile.toJson().toString()) {
        throw const BridgeFailure('conflict', '来源已改变，请重新获取模型');
      }
      await controller.saveModelService(
        profile.copyWith(
          models: models,
          modelLimits: discovery.limits,
          chatModel: models.contains(profile.chatModel)
              ? profile.chatModel
              : models.first,
          reasonerModel: models.contains(profile.reasonerModel)
              ? profile.reasonerModel
              : models.first,
        ),
        '',
      );
      job.models = models.length;
      job.success = true;
      job.stage = '登录完成 · 已获取 ${models.length} 个模型；/model 选择使用';
    } catch (error) {
      job.stage = job.token.isCancelled
          ? (authorized ? '已取消获取模型；已授权账号保留，可重新扫描' : '登录已取消')
          : error is BridgeFailure
          ? error.message
          : authorized
          ? '账号已授权，模型获取失败；可在 /provider 重新获取'
          : '登录未完成，请重新 /login 并在浏览器完成授权';
    } finally {
      job.done = true;
    }
  }
}
