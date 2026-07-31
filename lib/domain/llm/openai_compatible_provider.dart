import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart';

import 'llm_provider.dart';

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

  /// Error payloads are untrusted server input. Keep a useful diagnostic while
  /// avoiding an accidental multi-megabyte error page being buffered in memory.
  static const _maxErrorBodyBytes = 64 * 1024;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  }) async* {
    final url =
        '${config.baseUrl.replaceAll(RegExp(r"/+$"), "")}'
        '/chat/completions';

    final body = <String, dynamic>{
      'model': config.model,
      'stream': true,
      // `reasoning_content` round-trip only makes sense for models that emit
      // it (DeepSeek V4 and reasoners); a strict provider that rejects unknown
      // fields could 400 when history holds a previous answer's chain.
      'messages': messages
          .map(
            (m) => m.toOpenAiJson(
              includeReasoningContent:
                  config.capabilities.isReasoner ||
                  config.capabilities.sendThinkingField,
            ),
          )
          .toList(),
    };
    // DeepSeek V4 defaults thinking to ENABLED, so we must explicitly disable it
    // for fast normal chat (and enable it for deep-think). The `thinking` field
    // is DeepSeek-specific; `capabilities.sendThinkingField` gates it so other
    // OpenAI-compatible providers never receive it (which would 400).
    if (thinking != null && config.capabilities.sendThinkingField) {
      body['thinking'] = {'type': thinking ? 'enabled' : 'disabled'};
    }
    // Current xAI models use the OpenAI-compatible `reasoning_effort` field.
    // Grok 4.3 accepts `none`; Grok 4.5 always reasons, so normal mode leaves
    // its provider default untouched while deep-think requests high effort.
    if (thinking != null && config.capabilities.supportsReasoningEffort) {
      if (thinking) {
        body['reasoning_effort'] = 'high';
      } else if (config.capabilities.reasoningCanBeDisabled) {
        body['reasoning_effort'] = 'none';
      }
    }
    // Some legacy reasoner endpoints reject `tools`; callers avoid those paths,
    // but guard here too so a stray tool list can't break the request.
    if (tools != null &&
        tools.isNotEmpty &&
        config.capabilities.supportsTools) {
      body['tools'] = tools.map((t) => t.toJson()).toList();
      body['tool_choice'] = 'auto';
    }

    final Response<ResponseBody> response;
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
                'Authorization': 'Bearer ${config.apiKey}',
                'Content-Type': 'application/json',
                'Accept': 'text/event-stream',
              },
            ),
            data: jsonEncode(body),
            cancelToken: cancelToken,
          )
          .timeout(responseHeaderTimeout);
    } on DioException catch (e) {
      // Stop pressed during connection setup → end the stream quietly.
      if (CancelToken.isCancel(e)) return;
      throw await _humanizeError(e);
    } on TimeoutException {
      // If cancellation races with the timeout, stopping remains quiet.
      if (cancelToken?.isCancelled ?? false) return;
      throw Exception(
        '响应超时：服务端在 ${responseHeaderTimeout.inSeconds} 秒内没有开始返回数据，'
        '请检查网络或稍后重试。',
      );
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
      throw await _humanizeError(e);
    } on TimeoutException {
      // If cancellation races with the timeout, stopping remains quiet.
      if (cancelToken?.isCancelled ?? false) return;
      throw Exception(
        '响应超时：服务端在 ${_streamIdleTimeout.inSeconds} 秒内没有返回数据，'
        '请检查网络或稍后重试。',
      );
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

    final choices = json['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      return (chunks: const [], done: false);
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
        delta['reasoning_content'] as String? ??
        delta['reasoning'] as String?;
    return (
      chunks: [
        ChatChunk(
          contentDelta: delta['content'] as String?,
          reasoningDelta: reasoning,
          toolCalls: _parseToolCalls(delta['tool_calls']),
          finishReason: finishReason,
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
        return _clipErrorMessage(message);
      }
    }
    if (error is String && error.trim().isNotEmpty) {
      return _clipErrorMessage(error);
    }

    // A few compatible providers omit `error` but send an error-shaped
    // payload with a top-level message and no choices.
    final message = payload['message'];
    if (payload['choices'] == null && message is String && message.isNotEmpty) {
      return _clipErrorMessage(message);
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

  Future<Exception> _humanizeError(DioException e) async {
    final status = e.response?.statusCode;
    final apiMsg = await _extractApiMessage(e.response?.data);
    final detail = apiMsg == null ? '' : '：$apiMsg';
    if (status == 400) return Exception('请求有误（400）$detail');
    if (status == 401) return Exception('鉴权失败（401）：请检查 API Key 是否正确。');
    if (status == 402) return Exception('额度不足（402）：账户余额不足。');
    if (status == 404) {
      return Exception('接口未找到（404）：请检查 Base URL 或模型名是否正确。$detail');
    }
    if (status == 422) return Exception('参数有误（422）$detail');
    if (status == 429) return Exception('请求过于频繁（429）：稍后重试。');
    if (e.type == DioExceptionType.connectionTimeout) {
      return Exception('连接超时：请检查网络或 Base URL。');
    }
    if (e.type == DioExceptionType.receiveTimeout) {
      return Exception('响应超时：服务端长时间没有返回数据，请稍后重试。');
    }
    if (e.type == DioExceptionType.sendTimeout) {
      return Exception('请求发送超时：请检查网络后重试。');
    }
    if (e.type == DioExceptionType.connectionError) {
      return Exception('连接失败：请检查网络或 Base URL。');
    }
    if (e.type == DioExceptionType.badCertificate) {
      return Exception('TLS 证书校验失败：请检查 Base URL 是否可信。');
    }
    if (e.type == DioExceptionType.unknown) {
      return Exception('网络连接中断：请检查网络后重试。');
    }
    if (status != null) return Exception('请求失败（$status）$detail');
    return Exception('请求失败：${e.message ?? e.type.name}');
  }

  /// Best-effort extraction of the provider's error message from a (possibly
  /// streamed) error body. Never throws.
  Future<String?> _extractApiMessage(dynamic data) async {
    try {
      String? raw;
      if (data is ResponseBody) {
        final bytes = <int>[];
        await for (final chunk in data.stream) {
          final remaining = _maxErrorBodyBytes - bytes.length;
          if (remaining <= 0) break;
          if (chunk.length <= remaining) {
            bytes.addAll(chunk);
          } else {
            bytes.addAll(chunk.take(remaining));
            break;
          }
        }
        raw = utf8.decode(bytes, allowMalformed: true);
      } else if (data is String) {
        raw = data;
      } else if (data is Map) {
        return _messageFromMap(data);
      }
      if (raw == null || raw.trim().isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return _messageFromMap(decoded);
      } catch (_) {
        // Not JSON — fall through to the raw text.
      }
      final trimmed = raw.trim();
      // Grapheme-aware cut so we can't split an emoji/surrogate pair.
      return trimmed.length > 200
          ? '${trimmed.characters.take(200)}…'
          : trimmed;
    } catch (_) {
      return null;
    }
  }

  String? _messageFromMap(Map<dynamic, dynamic> map) {
    final err = map['error'];
    if (err is Map && err['message'] is String) {
      return _clipErrorMessage(err['message'] as String);
    }
    if (err is String) return _clipErrorMessage(err);
    if (map['message'] is String) {
      return _clipErrorMessage(map['message'] as String);
    }
    return null;
  }

  String _clipErrorMessage(String value) {
    final trimmed = value.trim();
    return trimmed.characters.length > 200
        ? '${trimmed.characters.take(200)}…'
        : trimmed;
  }
}
