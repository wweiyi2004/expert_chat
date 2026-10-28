import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'llm_http_errors.dart';
import 'llm_endpoint.dart';
import 'llm_provider.dart';
import 'llm_request_policy.dart';

/// LLM provider for any OpenAI-compatible `/chat/completions` SSE endpoint.
/// DeepSeek, OpenAI, xAI Grok, Kimi, 智谱 etc. all share this wire format
/// (`Authorization: Bearer` + SSE `data:` chunks).
class OpenAiCompatibleProvider implements LlmProvider {
  OpenAiCompatibleProvider({
    Dio? dio,
    this.responseHeaderTimeout = const Duration(seconds: 30),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               // Fail fast on a dead network; no receiveTimeout so long streamed
               // answers are never cut off mid-generation.
               connectTimeout: const Duration(seconds: 30),
             ),
           );

  final Dio _dio;

  /// Timeout for the request to reach its response headers. `connectTimeout`
  /// only covers reaching the server: a server that accepts but never responds
  /// (or a half-open proxy) would otherwise hang the UI forever. Only guards
  /// the header wait — the body is covered separately by [_streamIdleTimeout],
  /// so long streams are unaffected.
  final Duration responseHeaderTimeout;

  /// A stream can stay open for a long answer, but it must not wait forever
  /// without receiving even a heartbeat. This guards against half-open mobile
  /// and desktop connections while still allowing providers to stream slowly.
  static const _streamIdleTimeout = Duration(seconds: 90);

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
    final headerTimeout = config.responseHeaderTimeout ?? responseHeaderTimeout;
    if (cancelToken?.isCancelled ?? false) return;
    final url = LlmEndpoint.action(
      config.openAiCompatibleBaseUrl,
      'chat/completions',
    );

    final body = <String, dynamic>{
      'model': config.model,
      'stream': true,
      // OpenAI-compatible streaming APIs only include final token usage when
      // explicitly requested. Providers that reject this optional field still
      // receive the normal request and can be handled by their gateway policy.
      'stream_options': {'include_usage': true},
      // `reasoning_content` round-trip only makes sense for models that emit
      // it (DeepSeek V4 and reasoners); a strict provider that rejects unknown
      // fields could 400 when history holds a previous answer's chain.
      'messages': messages
          .where((m) => !m.isEmptyAssistant)
          .map(
            (m) => m.toOpenAiJson(
              includeReasoningContent:
                  config.capabilities.isReasoner ||
                  config.capabilities.sendThinkingField,
            ),
          )
          .toList(),
    };
    if (config.maxOutputTokens != null) {
      final model = ModelCatalog.normalizeId(config.model);
      final openAi =
          Uri.tryParse(config.baseUrl)?.host == 'api.openai.com' ||
          model.startsWith('gpt-5') ||
          model.startsWith('gpt-6') ||
          RegExp(r'^o[1-9]').hasMatch(model);
      body[openAi ? 'max_completion_tokens' : 'max_tokens'] =
          config.maxOutputTokens;
    }
    // DeepSeek V4 defaults thinking to ENABLED, so we must explicitly disable it
    // for fast normal chat (and enable it for deep-think). The `thinking` field
    // is DeepSeek-specific; `capabilities.sendThinkingField` gates it so other
    // OpenAI-compatible providers never receive it (which would 400).
    if (thinking != null && config.capabilities.sendThinkingField) {
      body['thinking'] = {'type': thinking ? 'enabled' : 'disabled'};
    }
    // DeepSeek V4: `reasoning_effort` (low/high/max) with thinking enabled.
    // Grok 4.3 accepts `none` to disable; Grok 4.5 always reasons, so normal
    // mode leaves its provider default untouched while deep-think requests high.
    if (thinking != null && config.capabilities.supportsReasoningEffort) {
      if (thinking ||
          (ModelCatalog.isConfigurableGpt(config.model) &&
              !config.capabilities.reasoningCanBeDisabled)) {
        body['reasoning_effort'] = reasoningEffortWire(
          config,
          reasoningEffort ?? ReasoningEffort.high,
        );
      } else if (config.capabilities.reasoningCanBeDisabled) {
        body['reasoning_effort'] = 'none';
      }
    }
    if (config.serviceTier != null && config.supportsPriorityTier) {
      body['service_tier'] = config.serviceTier;
    }
    // Some legacy reasoner endpoints reject `tools`; callers avoid those paths,
    // but guard here too so a stray tool list can't break the request.
    if (LlmRequestPolicy.canUseTools(config, tools)) {
      body['tools'] = tools!.map((t) => t.toJson()).toList();
      final force = forceToolName?.trim() ?? '';
      if (force == kToolChoiceRequired) {
        body['tool_choice'] = 'required';
      } else if (force.isNotEmpty) {
        body['tool_choice'] = {
          'type': 'function',
          'function': {'name': force},
        };
      } else {
        body['tool_choice'] = 'auto';
      }
    }

    final Response<ResponseBody> response;
    // Timing out the await alone leaves the socket open: the server keeps
    // generating (and billing) a response nobody reads. Route the request
    // through a token linked to the caller's so the timeout — or stop() —
    // actually aborts the connection.
    final requestToken = CancelToken();
    unawaited(
      cancelToken?.whenCancel.then(
        (e) => requestToken.cancel(e.error ?? e.message ?? 'cancelled'),
      ),
    );
    try {
      // The post future completes once response headers arrive; the body
      // stream is consumed lazily afterwards. Timing out here only guards the
      // header wait, never the long-lived body stream.
      response = await _dio
          .post<ResponseBody>(
            url,
            options: Options(
              responseType: ResponseType.stream,
              headers: {
                ...config.transportHeaders,
                if (config.authMode != 'none' &&
                    config.apiKey.trim().isNotEmpty)
                  'Authorization': 'Bearer ${config.apiKey}',
                'Content-Type': 'application/json',
                'Accept': 'text/event-stream',
              },
            ),
            data: jsonEncode(body),
            onSendProgress:config.onUploadProgress,
            cancelToken: requestToken,
          )
          .timeout(
            headerTimeout,
            onTimeout: () {
              requestToken.cancel('响应超时');
              throw TimeoutException('响应头等待超时', headerTimeout);
            },
          );
    } on DioException catch (e) {
      // Stop pressed during connection setup → end the stream quietly.
      if (CancelToken.isCancel(e)) return;
      throw await humanizeLlmHttpError(e, authMode: config.authMode);
    } on TimeoutException {
      // If cancellation races with the timeout, stopping remains quiet.
      if (cancelToken?.isCancelled ?? false) return;
      throw llmResponseTimeout(headerTimeout);
    }

    // allowMalformed: a connection dropped mid-multibyte-character leaves a
    // half sequence; strict utf8 would throw a FormatException that escapes the
    // `on DioException` handler below and surfaces as a raw crash. Lenient
    // decoding turns it into a harmless replacement char and the stream ends.
    final byteStream = response.data!.stream
        .cast<List<int>>()
        .transform(
          StreamTransformer.fromBind(
            const Utf8Decoder(allowMalformed: true).bind,
          ),
        )
        .transform(const LineSplitter())
        .timeout(_streamIdleTimeout);

    // Some gateways fold long JSON payloads across consecutive `data:` lines;
    // per the SSE spec those lines belong to ONE event and must be joined
    // with '\n' before parsing. Buffer them and parse at the blank-line event
    // boundary; the lone-line fast path below keeps streams that omit the
    // blank separator (like the fixtures) working unchanged.
    final pendingData = <String>[];

    try {
      await for (final line in byteStream) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          // Blank line = end of the current event.
          if (pendingData.isNotEmpty) {
            final event = _handleEventPayload(pendingData.join('\n'));
            pendingData.clear();
            for (final chunk in event.chunks) {
              yield chunk;
            }
            if (event.done) return;
          }
          continue;
        }
        if (!trimmed.startsWith('data:')) continue;
        final payload = trimmed.substring(5).trim();
        // `[DONE]` may carry trailing content (`data: [DONE] extra`); the
        // line is trimmed above, so a prefix match tolerates it. A wrapped
        // event that is still pending is flushed first so its data is not
        // lost when the gateway skips the blank separator.
        if (payload.startsWith('[DONE]')) {
          if (pendingData.isNotEmpty) {
            final event = _handleEventPayload(pendingData.join('\n'));
            for (final chunk in event.chunks) {
              yield chunk;
            }
          }
          return;
        }
        if (pendingData.isEmpty) {
          // Fast path: real streams usually send one complete JSON object per
          // line. Parse immediately; only treat the line as the start of a
          // wrapped multi-line event when it does not parse on its own.
          final decoded = _tryDecodeJson(payload);
          if (decoded != null) {
            final event = _handleParsedEvent(decoded);
            for (final chunk in event.chunks) {
              yield chunk;
            }
            continue;
          }
        }
        pendingData.add(payload);
      }
      // Stream ended without a trailing blank line — flush a wrapped event
      // whose final blank separator was never sent.
      if (pendingData.isNotEmpty) {
        final event = _handleEventPayload(pendingData.join('\n'));
        for (final chunk in event.chunks) {
          yield chunk;
        }
      }
    } on DioException catch (e) {
      // Stop pressed mid-stream → end quietly instead of surfacing an error.
      if (CancelToken.isCancel(e)) return;
      throw await humanizeLlmHttpError(e, authMode: config.authMode);
    } on TimeoutException {
      // If cancellation races with the timeout, stopping remains quiet.
      if (cancelToken?.isCancelled ?? false) return;
      throw llmResponseTimeout(_streamIdleTimeout, headers: false);
    }
  }

  /// Best-effort decode of one SSE event payload. Returns null for malformed
  /// fragments and for valid JSON that is not an object (both ignored).
  Map<String, dynamic>? _tryDecodeJson(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Handles one complete SSE event payload (consecutive `data:` lines joined
  /// with '\n'). Returns the chunks to yield; [done] marks the terminal
  /// `[DONE]` event.
  ({List<ChatChunk> chunks, bool done}) _handleEventPayload(String payload) {
    final trimmed = payload.trim();
    if (trimmed.startsWith('[DONE]')) return (chunks: const [], done: true);
    final json = _tryDecodeJson(trimmed);
    if (json == null) {
      // ignore keep-alive / malformed fragments
      return (chunks: const [], done: false);
    }
    return _handleParsedEvent(json);
  }

  ({List<ChatChunk> chunks, bool done}) _handleParsedEvent(
    Map<String, dynamic> json,
  ) {
    // Some OpenAI-compatible gateways return a 200 SSE response and put the
    // actual error in a `data:` event. Surface it instead of silently ending
    // with an empty answer.
    final streamError = _streamErrorMessage(json);
    if (streamError != null) {
      throw Exception('生成失败：$streamError');
    }

    final usage = LlmUsage.fromChatCompletions(json['usage']);
    final choices = json['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      return (
        chunks: usage == null ? const [] : [ChatChunk(usage: usage)],
        done: false,
      );
    }
    final choice = choices.first as Map<String, dynamic>;
    final delta = choice['delta'] as Map<String, dynamic>?;
    final finishReason = choice['finish_reason'] as String?;
    if (delta == null) {
      if (finishReason != null) {
        return (chunks: [ChatChunk(finishReason: finishReason)], done: false);
      }
      return (chunks: const [], done: false);
    }

    // Reasoning field names vary across OpenAI-compatible vendors:
    // DeepSeek → reasoning_content; some Grok / gateways → reasoning.
    final reasoning =
        delta['reasoning_content'] as String? ?? delta['reasoning'] as String?;
    return (
      chunks: [
        ChatChunk(
          contentDelta: delta['content'] as String?,
          reasoningDelta: reasoning,
          toolCalls: _parseToolCalls(delta['tool_calls']),
          finishReason: finishReason,
          usage: usage,
        ),
      ],
      done: false,
    );
  }

  String? _streamErrorMessage(Map<String, dynamic> payload) {
    final error = payload['error'];
    if (error is Map) {
      final message = error['message'] ?? error['detail'];
      if (message is String && message.trim().isNotEmpty) {
        return clipLlmErrorMessage(message);
      }
    }
    if (error is String && error.trim().isNotEmpty) {
      return clipLlmErrorMessage(error);
    }

    // A few compatible providers omit `error` but send an error-shaped
    // payload with a top-level message and no choices.
    final message = payload['message'];
    if (payload['choices'] == null && message is String && message.isNotEmpty) {
      return clipLlmErrorMessage(message);
    }
    return null;
  }

  List<ToolCall>? _parseToolCalls(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final out = <ToolCall>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final fn = e['function'] as Map<String, dynamic>?;
      out.add(
        ToolCall(
          index: (e['index'] as num?)?.toInt() ?? 0,
          id: e['id'] as String?,
          name: fn?['name'] as String?,
          argumentsJson: fn?['arguments'] as String? ?? '',
        ),
      );
    }
    return out.isEmpty ? null : out;
  }
}
