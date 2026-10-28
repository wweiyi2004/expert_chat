import '../domain/llm/llm_provider.dart';

/// Coding/Token Plan endpoints, kept separate from pay-as-you-go presets.
/// Model suggestions are editable; discovery remains authoritative for an account.
class SubscriptionEntry {
  const SubscriptionEntry(this.id,this.name,this.baseUrl,this.consoleUrl,{this.format=LlmApiFormat.openAiCompatible,this.models=const [],this.hint='使用此套餐控制台生成的专用 Key'});
  final String id,name,baseUrl,consoleUrl,hint;
  final LlmApiFormat format;
  final List<String> models;
  Map<String,Object?> view()=>{'key':id,'name':name,'description':hint,'kind':'subscription_key','base_url':baseUrl,'api_format':format.wire,'models':models};
  static const entries=[
    SubscriptionEntry('bigmodel','智谱 GLM Coding Plan','https://open.bigmodel.cn/api/anthropic/v1','https://bigmodel.cn/coding-plan/personal/overview',format:LlmApiFormat.anthropicMessages,models:['glm-5.3','glm-5.3-flash']),
    SubscriptionEntry('zai','Z.AI Coding Plan（国际）','https://api.z.ai/api/anthropic/v1','https://z.ai/manage-apikey/apikey-list',format:LlmApiFormat.anthropicMessages,models:['glm-5.3','glm-5.3-flash']),
    SubscriptionEntry('kimi-code','Kimi Code','https://api.kimi.com/coding/v1','https://www.kimi.com/code/console',format:LlmApiFormat.auto,models:['kimi-for-coding']),
    SubscriptionEntry('kimi-code-global','Kimi Code（国际）','https://api.kimi.ai/coding/v1','https://www.kimi.ai/code/console',format:LlmApiFormat.auto,models:['kimi-for-coding']),
    SubscriptionEntry('opencode-go','OpenCode Go','https://opencode.ai/inference/go/v1','https://opencode.ai/auth',hint:'Go 套餐 Key；保存后获取此接口可用模型'),
    SubscriptionEntry('minimax','MiniMax Token Plan（国内）','https://api.minimaxi.com/anthropic/v1','https://platform.minimaxi.com/subscribe/token-plan',format:LlmApiFormat.anthropicMessages,models:['MiniMax-M3','MiniMax-M2.7']),
    SubscriptionEntry('minimax-global','MiniMax Token Plan（国际）','https://api.minimax.io/anthropic/v1','https://platform.minimax.io/subscribe/token-plan',format:LlmApiFormat.anthropicMessages,models:['MiniMax-M3','MiniMax-M2.7']),
    SubscriptionEntry('aliyun-coding','阿里云百炼 Coding Plan','https://coding.dashscope.aliyuncs.com/v1','https://bailian.console.aliyun.com/',hint:'使用 Coding Plan 专用 Key（sk-sp-）'),
    SubscriptionEntry('aliyun-coding-global','阿里云 Model Studio Coding Plan（国际）','https://coding-intl.dashscope.aliyuncs.com/v1','https://modelstudio-intl.console.alibabacloud.com/',hint:'使用国际站 Coding Plan 专用 Key'),
    SubscriptionEntry('aliyun-token','阿里云百炼 Token Plan','https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1','https://bailian.console.aliyun.com/',hint:'Token Plan 专用 Key，与 Coding Plan 分开'),
    SubscriptionEntry('mimo-cn','小米 MiMo Token Plan（中国）','https://token-plan-cn.xiaomimimo.com/v1','https://platform.xiaomimimo.com/token-plan',models:['mimo-v2.5-pro','mimo-v2.5'],hint:'中国区套餐 Key（tp-）'),
    SubscriptionEntry('mimo-sgp','小米 MiMo Token Plan（新加坡）','https://token-plan-sgp.xiaomimimo.com/v1','https://platform.xiaomimimo.com/token-plan',models:['mimo-v2.5-pro','mimo-v2.5'],hint:'新加坡区套餐 Key'),
    SubscriptionEntry('mimo-ams','小米 MiMo Token Plan（欧洲）','https://token-plan-ams.xiaomimimo.com/v1','https://platform.xiaomimimo.com/token-plan',models:['mimo-v2.5-pro','mimo-v2.5'],hint:'欧洲区套餐 Key'),
    SubscriptionEntry('tencent','腾讯云 Token Plan（国内）','https://api.lkeap.cloud.tencent.com/plan/v3','https://console.cloud.tencent.com/tokenhub',hint:'使用 Token Plan 专用 Key，模型以控制台为准'),
    SubscriptionEntry('tencent-global','腾讯云 Token Plan（国际）','https://tokenhub-intl.tencentcloudmaas.com/plan/v3','https://console.tencentcloud.com/tokenhub',hint:'国际站 Token Plan 专用 Key'),
    SubscriptionEntry('ark','火山方舟 Coding Plan','https://ark.cn-beijing.volces.com/api/coding/v3','https://console.volcengine.com/ark/region:cn-beijing/codingplan',models:['ark-code-latest'],hint:'套餐专用端点；模型也可在方舟控制台选择'),
  ];
  static SubscriptionEntry? find(String id)=>entries.where((e)=>e.id==id).firstOrNull;
}
