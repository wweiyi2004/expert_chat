import '../llm/llm_provider.dart';
import '../../data/models.dart';
import 'wire_models.dart';

Map<String, Object?> encodeLlmConfig(LlmConfig c, {bool credentials = true}) =>
    {
      'baseUrl': c.baseUrl,
      'apiKey': credentials ? c.apiKey : '',
      'model': c.model,
      'apiFormat': c.apiFormat.wire,
      'serverWebSearch': c.serverWebSearch,
      'forceServerWebSearch': c.forceServerWebSearch,
      'allowReasoningRetry': c.allowReasoningRetry,
      'reasoningGuardEnabled': c.reasoningGuardEnabled,
      'responseHeaderTimeout': c.responseHeaderTimeout?.inMilliseconds,
      'maxOutputTokens': c.maxOutputTokens,
      'profileId': c.profileId,
      'routingSessionId': c.routingSessionId,
      'lockProfile': c.lockProfile,
      'authMode': c.authMode,
      'serviceTier': c.serviceTier,
      'modelFallbacks': c.modelFallbacks
          .map((v) => encodeLlmConfig(v, credentials: credentials))
          .toList(),
      'capabilities': {
        'isReasoner': c.capabilities.isReasoner,
        'supportsTools': c.capabilities.supportsTools,
        'sendThinkingField': c.capabilities.sendThinkingField,
        'supportsVision': c.capabilities.supportsVision,
        'supportsReasoningEffort': c.capabilities.supportsReasoningEffort,
        'reasoningCanBeDisabled': c.capabilities.reasoningCanBeDisabled,
        'supportsServerWebSearch': c.capabilities.supportsServerWebSearch,
        'reasoningEffortValues': c.capabilities.reasoningEffortValues,
      },
    };
LlmConfig decodeLlmConfig(Map<String, dynamic> j) {
  final c = wireMap(j['capabilities']);
  return LlmConfig(
    baseUrl: j['baseUrl'] as String,
    apiKey: j['apiKey'] as String? ?? '',
    model: j['model'] as String,
    apiFormat: LlmApiFormat.fromWire(j['apiFormat'] as String?),
    serverWebSearch: j['serverWebSearch'] == true,
    forceServerWebSearch: j['forceServerWebSearch'] == true,
    allowReasoningRetry: j['allowReasoningRetry'] != false,
    reasoningGuardEnabled: j['reasoningGuardEnabled'] != false,
    responseHeaderTimeout: j['responseHeaderTimeout'] == null
        ? null
        : Duration(milliseconds: j['responseHeaderTimeout'] as int),
    maxOutputTokens: j['maxOutputTokens'] as int?,
    profileId: j['profileId'] as String?,
    routingSessionId: j['routingSessionId'] as String?,
    lockProfile: j['lockProfile'] == true,
    authMode: j['authMode'] as String? ?? 'apiKey',
    serviceTier: j['serviceTier'] as String?,
    modelFallbacks: wireRows(j['modelFallbacks']).map(decodeLlmConfig).toList(),
    capabilities: c.isEmpty
        ? null
        : ModelCapabilities(
            isReasoner: c['isReasoner'] == true,
            supportsTools: c['supportsTools'] == true,
            sendThinkingField: c['sendThinkingField'] == true,
            supportsVision: c['supportsVision'] == true,
            supportsReasoningEffort: c['supportsReasoningEffort'] == true,
            reasoningCanBeDisabled: c['reasoningCanBeDisabled'] == true,
            supportsServerWebSearch: c['supportsServerWebSearch'] == true,
            reasoningEffortValues: (c['reasoningEffortValues'] as List?)
                ?.cast<String>(),
          ),
  );
}

Map<String, Object?> encodeToolCall(ToolCall c) => {
  'index': c.index,
  'id': c.id,
  'name': c.name,
  'argumentsJson': c.argumentsJson,
};
ToolCall decodeToolCall(Map<String, dynamic> c) => ToolCall(
  index: c['index'] as int,
  id: c['id'] as String?,
  name: c['name'] as String?,
  argumentsJson: c['argumentsJson'] as String? ?? '',
);
Map<String, Object?> encodeTool(ToolSpec t) => {
  'name': t.name,
  'description': t.description,
  'parameters': t.parameters,
};
ToolSpec decodeTool(Map<String, dynamic> t) => ToolSpec(
  name: t['name'] as String,
  description: t['description'] as String,
  parameters: wireMap(t['parameters']),
);
Map<String, Object?> encodeRequest(LlmRequestMessage m) => {
  'role': m.role.name,
  'content': m.content,
  'reasoningContent': m.reasoningContent,
  'toolCallId': m.toolCallId,
  'toolCalls': m.toolCalls.map(encodeToolCall).toList(),
  'imageDataUrls': m.imageDataUrls,
  'imageFileIds': m.imageFileIds,
  'responseOutputItems': m.responseOutputItems,
  'isToolImageObservation': m.isToolImageObservation,
  'toolImageCallId': m.toolImageCallId,
};
LlmRequestMessage decodeRequest(Map<String, dynamic> m) => LlmRequestMessage(
  role: MessageRole.values.byName(m['role'] as String),
  content: m['content'] as String,
  reasoningContent: m['reasoningContent'] as String?,
  toolCallId: m['toolCallId'] as String?,
  toolCalls: wireRows(m['toolCalls']).map(decodeToolCall).toList(),
  imageDataUrls: (m['imageDataUrls'] as List? ?? []).cast<String>(),
  imageFileIds: (m['imageFileIds'] as List? ?? []).cast<String>(),
  responseOutputItems: wireRows(m['responseOutputItems']),
  isToolImageObservation: m['isToolImageObservation'] == true,
  toolImageCallId: m['toolImageCallId'] as String?,
);
Map<String, Object?> encodeUsage(LlmUsage u) => {
  'inputTokens': u.inputTokens,
  'outputTokens': u.outputTokens,
  'cachedInputTokens': u.cachedInputTokens,
  'reasoningTokens': u.reasoningTokens,
  'cacheReported': u.cacheReported,
  'cost': u.cost,
  'currency': u.currency,
};
LlmUsage decodeUsage(Map<String, dynamic> u) => LlmUsage(
  inputTokens: u['inputTokens'] as int,
  outputTokens: u['outputTokens'] as int,
  cachedInputTokens: u['cachedInputTokens'] as int? ?? 0,
  reasoningTokens: u['reasoningTokens'] as int? ?? 0,
  cacheReported: u['cacheReported'] == true,
  cost: (u['cost'] as num?)?.toDouble(),
  currency: u['currency'] as String?,
);
Map<String, Object?> encodeChunk(ChatChunk c) => {
  'content': c.contentDelta,
  'reasoning': c.reasoningDelta,
  'tools': c.toolCalls?.map(encodeToolCall).toList(),
  'finish': c.finishReason,
  'search': c.serverSearchActivity?.toJson(),
  'citations': c.citations?.map((v) => v.toJson()).toList(),
  'native': c.responseOutputItems,
  'usage': c.usage == null ? null : encodeUsage(c.usage!),
  'route': c.actualConfig == null
      ? null
      : encodeLlmConfig(c.actualConfig!, credentials: false),
};
ChatChunk decodeChunk(Map<String, dynamic> c) => ChatChunk(
  contentDelta: c['content'] as String?,
  reasoningDelta: c['reasoning'] as String?,
  toolCalls: c['tools'] == null
      ? null
      : wireRows(c['tools']).map(decodeToolCall).toList(),
  finishReason: c['finish'] as String?,
  serverSearchActivity: c['search'] == null
      ? null
      : SearchActivity.fromJson(wireMap(c['search'])),
  citations: c['citations'] == null
      ? null
      : wireRows(c['citations']).map(Citation.fromJson).toList(),
  responseOutputItems: c['native'] == null ? null : wireRows(c['native']),
  usage: c['usage'] == null ? null : decodeUsage(wireMap(c['usage'])),
  actualConfig: c['route'] == null
      ? null
      : decodeLlmConfig(wireMap(c['route'])),
);
