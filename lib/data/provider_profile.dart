import 'package:uuid/uuid.dart';

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
  }) : id = id ?? _uuid.v4(),
       models = models ?? const [];

  final String id;

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

  ProviderProfile copyWith({
    String? name,
    String? baseUrl,
    String? chatModel,
    String? reasonerModel,
    List<String>? models,
  }) => ProviderProfile(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    chatModel: chatModel ?? this.chatModel,
    reasonerModel: reasonerModel ?? this.reasonerModel,
    models: models ?? this.models,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'chatModel': chatModel,
    'reasonerModel': reasonerModel,
    'models': models,
  };

  factory ProviderProfile.fromJson(Map<String, dynamic> json) =>
      ProviderProfile(
        id: json['id'] as String?,
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
  });

  final String name;
  final String baseUrl;
  final String chatModel;
  final String reasonerModel;
  final List<String> models;
  final ProviderPresetGroup group;

  /// Short note shown in the picker (path quirks, /v1 suffix, etc.).
  final String hint;

  ProviderProfile toProfile() => ProviderProfile(
    name: name,
    baseUrl: baseUrl,
    chatModel: chatModel,
    reasonerModel: reasonerModel,
    models: models,
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
      chatModel: 'deepseek-v4-flash',
      reasonerModel: 'deepseek-v4-pro',
      models: [
        'deepseek-v4-flash',
        'deepseek-v4-pro',
        'deepseek-v4-flash-vision-exp',
      ],
      hint: '不要加 /v1；官方联网 flash/pro/vision 均可；看图请选 flash-vision-exp',
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
      name: 'Google Gemini',
      group: ProviderPresetGroup.global,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      chatModel: 'gemini-2.5-flash',
      reasonerModel: 'gemini-2.5-pro',
      models: ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.0-flash'],
      hint: '官方 OpenAI 兼容端点',
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
  ];
}
