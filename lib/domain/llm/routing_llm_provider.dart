import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show CancelToken;

import 'anthropic_messages_provider.dart';
import 'gemini_native_provider.dart';
import 'llm_endpoint.dart';
import 'llm_http_errors.dart';
import 'llm_provider.dart';
import 'openai_compatible_files_client.dart';
import 'openai_compatible_provider.dart';
import 'responses_api_provider.dart';

typedef _Route = ({LlmApiFormat format, String baseUrl});

/// Auto tries a bounded set of same-origin protocols only after a clear HTTP
/// protocol rejection. Accepted/partial responses and tool continuations are
/// never replayed under a different protocol.
class RoutingLlmProvider implements LlmProvider {
  RoutingLlmProvider({
    OpenAiCompatibleProvider? chatCompletions,
    ResponsesApiProvider? responses,
    GeminiNativeProvider? geminiNative,
    AnthropicMessagesProvider? anthropic,
    OpenAiCompatibleFilesClient? files,
  }) : _chat = chatCompletions ?? OpenAiCompatibleProvider(),
       _responses = responses ?? ResponsesApiProvider(),
       _gemini = geminiNative ?? GeminiNativeProvider(),
       _anthropic = anthropic ?? AnthropicMessagesProvider(),
       _files = files ?? OpenAiCompatibleFilesClient();

  final OpenAiCompatibleProvider _chat;
  final ResponsesApiProvider _responses;
  final GeminiNativeProvider _gemini;
  final AnthropicMessagesProvider _anthropic;
  final OpenAiCompatibleFilesClient _files;
  final _routes = <String, _Route>{};

  String _key(LlmConfig config) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            config.baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
            config.apiKey,
            config.model,
            config.useServerWebSearch,
          ]),
        ),
      )
      .toString();

  /// Session-local only: keys are digests, no credentials are persisted.
  LlmApiFormat? detectedFormat(LlmConfig config) =>
      _routes[_key(config)]?.format;

  static LlmApiFormat? _nativeFormat(List<LlmRequestMessage> messages) {
    for (final m in messages.reversed) {
      for (final item in m.responseOutputItems) {
        if (item.containsKey('functionCall') ||
            item.containsKey('thoughtSignature') ||
            item.containsKey('text') && !item.containsKey('type')) {
          return LlmApiFormat.geminiNative;
        }
        if ({
          'thinking',
          'redacted_thinking',
          'tool_use',
          'text',
        }.contains(item['type'])) {
          return LlmApiFormat.anthropicMessages;
        }
        if ({'reasoning', 'function_call', 'message'}.contains(item['type'])) {
          return LlmApiFormat.openAiResponses;
        }
      }
    }
    return null;
  }

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    if (cancelToken?.isCancelled ?? false) return;
    final automatic = config.apiFormat == LlmApiFormat.auto;
    final key = _key(config);
    final pinned = _nativeFormat(messages);
    final continuation =
        pinned != null ||
        messages.any((m) => m.toolCalls.isNotEmpty || m.toolCallId != null);
    final preferred =
        pinned ??
        (config.useServerWebSearch
            ? LlmApiFormat.openAiResponses
            : config.effectiveApiFormat);
    final formats = <LlmApiFormat>{
      preferred,
      if (automatic && !continuation && !config.useServerWebSearch) ...[
        LlmApiFormat.openAiCompatible,
        LlmApiFormat.openAiResponses,
        LlmApiFormat.anthropicMessages,
        LlmApiFormat.geminiNative,
      ],
    };
    final cached = automatic ? _routes[key] : null;
    final candidates = <_Route>{
      if (cached != null && (pinned == null || pinned == cached.format)) cached,
      for (final format in formats)
        for (final base
            in automatic && !continuation
                ? LlmEndpoint.roots(config.baseUrl, format: format)
                : [LlmEndpoint.base(config.baseUrl)])
          (format: format, baseUrl: base),
    }.toList();
    var attempted = 0;
    for (final route in candidates) {
      if (cancelToken?.isCancelled ?? false) return;
      attempted++;
      var emitted = false;
      try {
        final selected = config.copyWith(
          baseUrl: route.baseUrl,
          apiFormat: route.format,
        );
        final resolved =
            config.authMode != 'chatgpt' &&
                (route.format == LlmApiFormat.openAiCompatible ||
                    route.format == LlmApiFormat.openAiResponses)
            ? await _files.attachFileIds(
                config: selected,
                messages: messages,
                cancelToken: cancelToken,
              )
            : messages;
        if (cancelToken?.isCancelled ?? false) return;
        final LlmProvider provider = switch (route.format) {
          LlmApiFormat.geminiNative => _gemini,
          LlmApiFormat.openAiResponses => _responses,
          LlmApiFormat.anthropicMessages => _anthropic,
          _ => _chat,
        };
        await for (final chunk in provider.streamChat(
          config: selected,
          messages: resolved,
          tools: tools,
          thinking: thinking,
          reasoningEffort: reasoningEffort,
          forceToolName: forceToolName,
          cancelToken: cancelToken,
        )) {
          emitted = true;
          if (automatic &&
              ((chunk.contentDelta?.isNotEmpty ?? false) ||
                  (chunk.reasoningDelta?.isNotEmpty ?? false) ||
                  (chunk.toolCalls?.isNotEmpty ?? false) ||
                  chunk.finishReason != null)) {
            _routes.remove(key);
            _routes[key] = route;
            if (_routes.length > 128) _routes.remove(_routes.keys.first);
          }
          yield chunk;
        }
        if (automatic && !emitted && !(cancelToken?.isCancelled ?? false)) {
          throw const FormatException('服务已接受请求，但未返回可识别的流式响应；请检查接口格式。');
        }
        return;
      } on LlmHttpException catch (error) {
        if (cancelToken?.isCancelled ?? false) return;
        if (!automatic ||
            continuation ||
            emitted ||
            !error.isProtocolRejection) {
          rethrow;
        }
        if (_routes[key] == route) _routes.remove(key);
        if (attempted == candidates.length) {
          throw LlmHttpException(
            '自动协议尝试未成功（已尝试 $attempted 个接口）。请确认 Base URL、模型名与服务支持的协议。最后错误：${error.message}',
            statusCode: error.statusCode,
          );
        }
      }
    }
  }
}
