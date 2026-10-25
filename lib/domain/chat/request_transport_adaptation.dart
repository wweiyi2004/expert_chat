import '../llm/llm_provider.dart';

/// Adapt only transient request history. Stored originals remain available for
/// UI/recovery. Plain same-wire DeepSeek reasoning is a required continuation
/// field, unlike account/model-bound native signatures and uploaded file IDs.
List<LlmRequestMessage> adaptHistoryForTransport(
  List<LlmRequestMessage> messages, {
  required LlmConfig previous,
  required LlmConfig next,
}) {
  final explicitKeyChanged =
      previous.authMode == 'apiKey' &&
      next.authMode == 'apiKey' &&
      previous.apiKey != next.apiKey;
  final identityChanged =
      previous.baseUrl != next.baseUrl ||
      previous.profileId != next.profileId ||
      previous.model != next.model ||
      previous.apiFormat != next.apiFormat ||
      previous.authMode != next.authMode ||
      explicitKeyChanged;
  final keepVision = next.capabilities.supportsVision;
  final droppingVision =
      !keepVision &&
      (previous.capabilities.supportsVision ||
          messages.any((message) => message.hasImageParts));
  if (!identityChanged && !droppingVision) return List.of(messages);
  final sameDeepSeekChat =
      previous.baseUrl == next.baseUrl &&
      previous.model == next.model &&
      previous.isDeepSeek &&
      previous.effectiveApiFormat == LlmApiFormat.openAiCompatible &&
      next.effectiveApiFormat == LlmApiFormat.openAiCompatible;
  return [
    for (final message in messages)
      LlmRequestMessage(
        role: message.role,
        content:
            '${message.content}${!keepVision && message.hasImageParts
                ? '\n【图片/截图像素未发送：所选模型不支持视觉。原始图片仍保留在界面；请依据已有公开文字或切换视觉模型。】'
                : identityChanged && message.imageFileIds.isNotEmpty && message.imageDataUrls.isEmpty
                ? '\n【原渠道上传文件引用已移除；需要时请重新读取原附件。】'
                : ''}',
        reasoningContent: !identityChanged || sameDeepSeekChat
            ? message.reasoningContent
            : null,
        toolCallId: message.toolCallId,
        toolCalls: message.toolCalls,
        imageDataUrls: keepVision ? message.imageDataUrls : const [],
        imageFileIds: keepVision && !identityChanged
            ? message.imageFileIds
            : const [],
        responseOutputItems: !identityChanged && !droppingVision
            ? message.responseOutputItems
            : const [],
        isToolImageObservation: message.isToolImageObservation,
        toolImageCallId: message.toolImageCallId,
      ),
  ];
}
