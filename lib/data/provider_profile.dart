import 'package:uuid/uuid.dart';
import 'model_token_limits.dart';

import '../domain/llm/model_catalog.dart';

const _uuid = Uuid();

/// A named, switchable LLM endpoint configuration. The app keeps a list of
/// these and one is "active" at a time (M3). The API key is stored separately
/// in secure storage keyed by [id]; it is NOT serialized into the profile JSON.
class ProviderProfile {
  ProviderProfile({
    String? id,
    required this.name,
    required this.baseUrl,
    required this.chatModel,
    required this.reasonerModel,
    List<String>? models,
    this.apiFormat = LlmApiFormat.auto,
    this.authMode = 'apiKey',
    this.enabled = true,
    this.modelLimits = const {},
  }) : id = id ?? _uuid.v4(),
       models = models ?? const [];

  final String id;
  final String authMode;
  final bool enabled;
  final Map<String, ModelTokenLimits> modelLimits;

  /// User-facing label, e.g. "DeepSeek" or "My OpenAI".
  final String name;

  /// Base URL without the `/chat/completions` suffix.
  final String baseUrl;

  /// Default model used for normal chat.
  final String chatModel;

  /// Model used when "深度思考" is on. May equal [chatModel] for providers
  /// that have no dedicated reasoner.
  final String reasonerModel;

  /// All selectable model ids for this provider (for the model dropdown).
  final List<String> models;

  /// Wire protocol preference. Auto is resolved by the LLM router at runtime.
  final LlmApiFormat apiFormat;

  LlmApiFormat get effectiveApiFormat =>
      GeminiEndpoint.resolveFormat(format: apiFormat, baseUrl: baseUrl);

  ProviderProfile copyWith({
    String? name,
    String? baseUrl,
    String? chatModel,
    String? reasonerModel,
    List<String>? models,
    LlmApiFormat? apiFormat,
    String? authMode,
    bool? enabled,
    Map<String, ModelTokenLimits>? modelLimits,
  }) => ProviderProfile(
    id: id,
    authMode: authMode ?? this.authMode,
    enabled: enabled ?? this.enabled,
    modelLimits: modelLimits ?? this.modelLimits,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    chatModel: chatModel ?? this.chatModel,
    reasonerModel: reasonerModel ?? this.reasonerModel,
    models: models ?? this.models,
    apiFormat: apiFormat ?? this.apiFormat,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (!enabled) 'enabled': false,
    if (authMode != 'apiKey') 'authMode': authMode,
    'name': name,
    'baseUrl': baseUrl,
    'chatModel': chatModel,
    'reasonerModel': reasonerModel,
    'models': models,
    if (modelLimits.isNotEmpty)
      'modelLimits': modelLimits.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
    if (apiFormat != LlmApiFormat.auto) 'apiFormat': apiFormat.wire,
  };

  factory ProviderProfile.fromJson(Map<String, dynamic> json) =>
      ProviderProfile(
        id: json['id'] as String?,
        enabled: json['enabled'] != false,
        authMode: json['authMode'] as String? ?? 'apiKey',
        name: json['name'] as String? ?? '未命名',
        baseUrl: json['baseUrl'] as String? ?? '',
        chatModel: json['chatModel'] as String? ?? '',
        reasonerModel:
            json['reasonerModel'] as String? ??
            json['chatModel'] as String? ??
            '',
        models: (json['models'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        modelLimits: (json['modelLimits'] as Map<String, dynamic>? ?? {}).map(
          (key, value) => MapEntry(
            key,
            ModelTokenLimits.fromJson(Map<String, dynamic>.from(value as Map)),
          ),
        ),
        apiFormat: LlmApiFormat.fromWire(json['apiFormat'] as String?),
      );
}

/// Built-in provider presets that one-click fill the base URL + model list.
/// Users still supply their own API key. Sourced from each provider's
/// OpenAI-compatible Chat Completions endpoint docs.
enum ProviderPresetGroup {
  china('国内'),
  global('国际'),
  local('本地');

  const ProviderPresetGroup(this.label);
  final String label;
}

class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.baseUrl,
    required this.chatModel,
    required this.reasonerModel,
    required this.models,
    this.group = ProviderPresetGroup.global,
    this.hint = '',
    this.apiFormat = LlmApiFormat.auto,
  });

  final String name;
  final String baseUrl;
  final String chatModel;
  final String reasonerModel;
  final List<String> models;
  final ProviderPresetGroup group;

  /// Short note shown in the picker (path quirks, /v1 suffix, etc.).
  final String hint;

  final LlmApiFormat apiFormat;

  ProviderProfile toProfile() => ProviderProfile(
    authMode: group == ProviderPresetGroup.local ? 'none' : 'apiKey',
    name: name,
    baseUrl: baseUrl,
    chatModel: chatModel,
    reasonerModel: reasonerModel,
    models: models,
    apiFormat: apiFormat,
  );

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        baseUrl.toLowerCase().contains(q) ||
        chatModel.toLowerCase().contains(q) ||
        reasonerModel.toLowerCase().contains(q) ||
        models.any((m) => m.toLowerCase().contains(q)) ||
        hint.toLowerCase().contains(q);
  }

  static const presets = <ProviderPreset>[
    ProviderPreset(
      name: 'DeepSeek',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.deepseek.com',
      chatModel: KnownModels.flash,
      reasonerModel: KnownModels.reasoner,
      models: KnownModels.all,
      hint:
          'V4.1 Flash 支持识图与思考，Pro 适合复杂推理；官方联网通过 Search / Fetch API，复用 DeepSeek Key',
    ),
    ProviderPreset(
      name: 'Kimi (Moonshot)',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.moonshot.cn/v1',
      chatModel: 'kimi-k2-turbo-preview',
      reasonerModel: 'kimi-thinking-preview',
      models: [
        'kimi-k2-turbo-preview',
        'moonshot-v1-8k',
        'moonshot-v1-32k',
        'moonshot-v1-128k',
        'kimi-thinking-preview',
      ],
    ),
    ProviderPreset(
      name: '智谱 GLM',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      chatModel: 'glm-4.5',
      reasonerModel: 'glm-4.5',
      models: ['glm-4.5', 'glm-4-plus', 'glm-4-air', 'glm-4v-plus'],
    ),
    ProviderPreset(
      name: '阿里云百炼 (通义)',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      chatModel: 'qwen-plus',
      reasonerModel: 'qwen-plus',
      models: [
        'qwen-plus',
        'qwen-max',
        'qwen-turbo',
        'qwen-long',
        'qwen-vl-max',
      ],
      hint: '必须用 compatible-mode 路径',
    ),
    ProviderPreset(
      name: '火山方舟 (豆包)',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
      chatModel: 'doubao-seed-1.6',
      reasonerModel: 'doubao-seed-1.6',
      models: ['doubao-seed-1.6', 'doubao-pro-32k', 'doubao-lite-32k'],
      hint: '控制台里的推理接入点 ID 也可当模型名',
    ),
    ProviderPreset(
      name: '百度千帆',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://qianfan.baidubce.com/v2',
      chatModel: 'ernie-4.5-turbo-128k',
      reasonerModel: 'ernie-x1-turbo-32k',
      models: ['ernie-4.5-turbo-128k', 'ernie-4.5-8k', 'ernie-x1-turbo-32k'],
    ),
    ProviderPreset(
      name: '腾讯混元',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.hunyuan.cloud.tencent.com/v1',
      chatModel: 'hunyuan-turbos-latest',
      reasonerModel: 'hunyuan-t1-latest',
      models: ['hunyuan-turbos-latest', 'hunyuan-large', 'hunyuan-t1-latest'],
    ),
    ProviderPreset(
      name: 'MiniMax',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.minimaxi.com/v1',
      chatModel: 'MiniMax-M2.1',
      reasonerModel: 'MiniMax-M2.1',
      models: ['MiniMax-M2.1', 'MiniMax-Text-01', 'MiniMax-VL-01'],
    ),
    ProviderPreset(
      name: '硅基流动 SiliconFlow',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.siliconflow.cn/v1',
      chatModel: 'deepseek-ai/DeepSeek-V3',
      reasonerModel: 'deepseek-ai/DeepSeek-R1',
      models: [
        'deepseek-ai/DeepSeek-V3',
        'deepseek-ai/DeepSeek-R1',
        'Qwen/Qwen3-235B-A22B',
        'moonshotai/Kimi-K2-Instruct',
      ],
    ),
    ProviderPreset(
      name: '阶跃星辰 StepFun',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.stepfun.com/v1',
      chatModel: 'step-2-mini',
      reasonerModel: 'step-r1-v-mini',
      models: ['step-2-mini', 'step-2-16k', 'step-r1-v-mini'],
    ),
    ProviderPreset(
      name: '零一万物 Yi',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.lingyiwanwu.com/v1',
      chatModel: 'yi-lightning',
      reasonerModel: 'yi-lightning',
      models: ['yi-lightning', 'yi-large', 'yi-spark'],
    ),
    ProviderPreset(
      name: '百川智能',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.baichuan-ai.com/v1',
      chatModel: 'Baichuan4-Turbo',
      reasonerModel: 'Baichuan4-Turbo',
      models: ['Baichuan4-Turbo', 'Baichuan4', 'Baichuan3-Turbo'],
    ),
    ProviderPreset(
      name: '讯飞星火',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://spark-api-open.xf-yun.com/v1',
      chatModel: 'generalv3.5',
      reasonerModel: 'spark-x1',
      models: ['spark-x1', '4.0Ultra', 'generalv3.5', 'lite'],
      hint: 'HTTP 开放接口，不是 WebSocket 那套',
    ),
    ProviderPreset(
      name: '无问芯穹 Infini-AI',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://cloud.infini-ai.com/maas/v1',
      chatModel: 'deepseek-v3',
      reasonerModel: 'deepseek-r1',
      models: ['deepseek-v3', 'deepseek-r1', 'qwen3-235b-a22b'],
      hint: '控制台里的模型 ID 可能带部署前缀',
    ),
    ProviderPreset(
      name: '302.AI',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.302.ai/v1',
      chatModel: 'gpt-4.1-mini',
      reasonerModel: 'deepseek-reasoner',
      models: [
        'gpt-4.1-mini',
        'gpt-4o',
        'claude-sonnet-4-0',
        'deepseek-chat',
        'deepseek-reasoner',
      ],
      hint: '聚合转发，模型名以控制台为准',
    ),
    ProviderPreset(
      name: 'PPIO 派欧云',
      group: ProviderPresetGroup.china,
      baseUrl: 'https://api.ppinfra.com/v3/openai',
      chatModel: 'deepseek/deepseek-v3',
      reasonerModel: 'deepseek/deepseek-r1',
      models: [
        'deepseek/deepseek-v3',
        'deepseek/deepseek-r1',
        'qwen/qwen3-235b-a22b-fp8',
      ],
    ),
    ProviderPreset(
      name: '阿里云百炼国际',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
      chatModel: 'qwen-plus',
      reasonerModel: 'qwen-plus',
      models: ['qwen-plus', 'qwen-max', 'qwen-turbo', 'qwen-vl-max'],
      hint: '海外区 DashScope，国内请用「阿里云百炼」',
    ),
    ProviderPreset(
      name: 'Grok (xAI)',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.x.ai/v1',
      chatModel: 'grok-4.3',
      reasonerModel: 'grok-4.5',
      models: [
        'grok-4.3',
        'grok-4.5',
        'grok-4.20-0309-non-reasoning',
        'grok-4.20-0309-reasoning',
        'grok-4.20-multi-agent-0309',
        'grok-build-0.1',
        'grok-2-vision-1212',
      ],
      hint: 'Base URL 必须带 /v1',
    ),
    ProviderPreset(
      name: 'OpenAI',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.openai.com/v1',
      chatModel: 'gpt-4o',
      reasonerModel: 'o3-mini',
      models: ['gpt-4o', 'gpt-4o-mini', 'gpt-4.1', 'o3-mini', 'o1'],
    ),
    ProviderPreset(
      name: 'OpenRouter',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://openrouter.ai/api/v1',
      chatModel: 'openai/gpt-4o-mini',
      reasonerModel: 'openai/o3-mini',
      models: [
        'openai/gpt-4o-mini',
        'openai/o3-mini',
        'anthropic/claude-sonnet-4',
        'google/gemini-2.5-pro',
        'deepseek/deepseek-chat',
      ],
      hint: '一个 Key 转接多家模型，模型名带厂商前缀',
    ),
    ProviderPreset(
      name: 'Google Gemini (原生 API)',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      chatModel: 'gemini-2.5-flash',
      reasonerModel: 'gemini-2.5-pro',
      models: ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.0-flash'],
      hint: '官方 Gemini 原生端点 (/v1beta/models)',
      apiFormat: LlmApiFormat.geminiNative,
    ),
    ProviderPreset(
      name: 'Google Gemini',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      chatModel: 'gemini-2.5-flash',
      reasonerModel: 'gemini-2.5-pro',
      models: ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.0-flash'],
      hint: '官方 OpenAI 兼容端点 (/v1beta/openai)',
      apiFormat: LlmApiFormat.openAiCompatible,
    ),
    ProviderPreset(
      name: 'Groq',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.groq.com/openai/v1',
      chatModel: 'llama-3.3-70b-versatile',
      reasonerModel: 'deepseek-r1-distill-llama-70b',
      models: [
        'llama-3.3-70b-versatile',
        'llama-3.1-8b-instant',
        'deepseek-r1-distill-llama-70b',
        'openai/gpt-oss-120b',
      ],
    ),
    ProviderPreset(
      name: 'Together AI',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.together.xyz/v1',
      chatModel: 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
      reasonerModel: 'deepseek-ai/DeepSeek-R1',
      models: [
        'meta-llama/Llama-3.3-70B-Instruct-Turbo',
        'Qwen/Qwen3-235B-A22B-fp8',
        'deepseek-ai/DeepSeek-R1',
      ],
    ),
    ProviderPreset(
      name: 'Fireworks',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.fireworks.ai/inference/v1',
      chatModel: 'accounts/fireworks/models/llama-v3p3-70b-instruct',
      reasonerModel: 'accounts/fireworks/models/deepseek-r1',
      models: [
        'accounts/fireworks/models/llama-v3p3-70b-instruct',
        'accounts/fireworks/models/deepseek-r1',
      ],
    ),
    ProviderPreset(
      name: 'Mistral',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.mistral.ai/v1',
      chatModel: 'mistral-large-latest',
      reasonerModel: 'magistral-medium-latest',
      models: [
        'mistral-large-latest',
        'mistral-small-latest',
        'magistral-medium-latest',
        'pixtral-large-latest',
      ],
    ),
    ProviderPreset(
      name: 'Perplexity',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.perplexity.ai',
      chatModel: 'sonar',
      reasonerModel: 'sonar-reasoning-pro',
      models: ['sonar', 'sonar-pro', 'sonar-reasoning', 'sonar-reasoning-pro'],
      hint: '不要加 /v1',
    ),
    ProviderPreset(
      name: 'NVIDIA NIM',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://integrate.api.nvidia.com/v1',
      chatModel: 'meta/llama-3.3-70b-instruct',
      reasonerModel: 'deepseek-ai/deepseek-r1',
      models: [
        'meta/llama-3.3-70b-instruct',
        'deepseek-ai/deepseek-r1',
        'google/gemma-3-27b-it',
      ],
    ),
    ProviderPreset(
      name: 'Cerebras',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.cerebras.ai/v1',
      chatModel: 'llama-3.3-70b',
      reasonerModel: 'llama-3.3-70b',
      models: ['llama-3.3-70b', 'llama3.1-8b', 'qwen-3-32b'],
    ),
    ProviderPreset(
      name: 'Deepinfra',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.deepinfra.com/v1/openai',
      chatModel: 'meta-llama/Llama-3.3-70B-Instruct',
      reasonerModel: 'deepseek-ai/DeepSeek-R1',
      models: [
        'meta-llama/Llama-3.3-70B-Instruct',
        'deepseek-ai/DeepSeek-R1',
        'Qwen/Qwen3-235B-A22B',
      ],
    ),
    ProviderPreset(
      name: 'Hugging Face',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://router.huggingface.co/v1',
      chatModel: 'Qwen/Qwen2.5-72B-Instruct',
      reasonerModel: 'deepseek-ai/DeepSeek-R1',
      models: [
        'Qwen/Qwen2.5-72B-Instruct',
        'meta-llama/Llama-3.3-70B-Instruct',
        'deepseek-ai/DeepSeek-R1',
      ],
      hint: '用 HF Token 当 API Key',
    ),
    ProviderPreset(
      name: 'GitHub Models',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://models.github.ai/inference',
      chatModel: 'gpt-4o-mini',
      reasonerModel: 'o3-mini',
      models: ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1', 'o3-mini'],
      hint: '用 GitHub PAT 当 API Key；地址不要再加 /v1',
    ),
    ProviderPreset(
      name: 'Novita',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.novita.ai/v3/openai',
      chatModel: 'deepseek/deepseek-v3-0324',
      reasonerModel: 'deepseek/deepseek-r1',
      models: [
        'deepseek/deepseek-v3-0324',
        'deepseek/deepseek-r1',
        'meta-llama/llama-3.3-70b-instruct',
      ],
    ),
    ProviderPreset(
      name: 'Cohere',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://api.cohere.ai/compatibility/v1',
      chatModel: 'command-a-03-2025',
      reasonerModel: 'command-a-reasoning-08-2025',
      models: [
        'command-a-03-2025',
        'command-r-plus',
        'command-a-reasoning-08-2025',
      ],
      hint: '官方 OpenAI 兼容层',
    ),
    ProviderPreset(
      name: 'Ollama',
      group: ProviderPresetGroup.local,
      baseUrl: 'http://127.0.0.1:11434/v1',
      chatModel: 'llama3.2',
      reasonerModel: 'deepseek-r1',
      models: ['llama3.2', 'qwen3', 'deepseek-r1', 'gemma3'],
      hint: '本地服务，API Key 可随便填',
    ),
    ProviderPreset(
      name: 'LM Studio',
      group: ProviderPresetGroup.local,
      baseUrl: 'http://127.0.0.1:1234/v1',
      chatModel: 'local-model',
      reasonerModel: 'local-model',
      models: ['local-model'],
      hint: '以 LM Studio 里加载的模型名为准',
    ),
    ProviderPreset(
      name: 'vLLM',
      group: ProviderPresetGroup.local,
      baseUrl: 'http://127.0.0.1:8000/v1',
      chatModel: 'default',
      reasonerModel: 'default',
      models: ['default'],
    ),
    ProviderPreset(
      name: 'llama.cpp',
      group: ProviderPresetGroup.local,
      baseUrl: 'http://127.0.0.1:8080/v1',
      chatModel: 'local-model',
      reasonerModel: 'local-model',
      models: ['local-model'],
      hint: 'llama-server 默认端口 8080',
    ),

    ProviderPreset(
      name: 'OpenCode Console / Zen (OpenAI)',
      baseUrl: 'https://opencode.ai/inference/openai/v1',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.auto,
      hint: '登录 OpenCode 控制台取得 Key；GPT、Grok 与 OpenAI 兼容模型',
    ),
    ProviderPreset(
      name: 'OpenCode Go (OpenAI)',
      baseUrl: 'https://opencode.ai/inference/go/openai/v1',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.auto,
      hint: '使用 OpenCode Go 套餐专用 Key',
    ),
    ProviderPreset(
      name: 'OpenCode Console (Claude)',
      baseUrl: 'https://opencode.ai/inference/anthropic/v1',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.anthropicMessages,
      hint: 'Claude 与 Anthropic 兼容模型',
    ),
    ProviderPreset(
      name: 'OpenCode Go (Claude)',
      baseUrl: 'https://opencode.ai/inference/go/anthropic/v1',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.anthropicMessages,
      hint: 'OpenCode Go 的 Anthropic 协议模型',
    ),
    ProviderPreset(
      name: 'OpenCode Console (Gemini)',
      baseUrl: 'https://opencode.ai/inference/google/v1beta',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.geminiNative,
      hint: 'Gemini 原生协议模型',
    ),
    ProviderPreset(
      name: 'OpenCode Go (Gemini)',
      baseUrl: 'https://opencode.ai/inference/go/google/v1beta',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.geminiNative,
      hint: 'OpenCode Go 的 Gemini 原生模型',
    ),
    ProviderPreset(
      name: '智谱 GLM Coding Plan',
      baseUrl: 'https://open.bigmodel.cn/api/coding/paas/v4',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.openAiCompatible,
      hint: '套餐专用地址；可用性以账号与平台支持范围为准',
    ),
    ProviderPreset(
      name: 'Z.AI GLM Coding Plan',
      baseUrl: 'https://api.z.ai/api/coding/paas/v4',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.openAiCompatible,
      hint: '国际 Coding Plan，使用对应套餐 Key',
    ),
    ProviderPreset(
      name: 'Kimi Code / Coding Plan',
      baseUrl: 'https://api.kimi.com/coding/v1',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.auto,
      hint: 'Kimi Code 专用 Key，与 Moonshot 按量 API 分开',
    ),
    ProviderPreset(
      name: '阿里云 Coding Plan',
      baseUrl: 'https://coding.dashscope.aliyuncs.com/v1',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.openAiCompatible,
      hint: '使用 sk-sp- 开头的套餐专用 Key',
    ),
    ProviderPreset(
      name: 'MiniMax M Plan / Coding Plan',
      baseUrl: 'https://api.minimaxi.com/anthropic/v1',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.anthropicMessages,
      hint: '使用 M Plan / Coding Plan Key，与普通 API 计费分开',
    ),
    ProviderPreset(
      name: 'Anthropic Claude API',
      baseUrl: 'https://api.anthropic.com/v1',
      chatModel: '',
      reasonerModel: '',
      models: [],
      apiFormat: LlmApiFormat.anthropicMessages,
      hint: '官方 API Key，不是 Claude Pro/Max 网页订阅登录',
    ),
  ];
}
