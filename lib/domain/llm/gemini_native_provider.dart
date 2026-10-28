import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models.dart';
import 'llm_http_errors.dart';
import 'llm_provider.dart';
import 'llm_request_policy.dart';

/// LLM provider for Google Gemini native REST API
/// (`/v1beta/models/{model}:streamGenerateContent?alt=sse`).
class GeminiNativeProvider implements LlmProvider {
  GeminiNativeProvider({
    Dio? dio,
    this.responseHeaderTimeout = const Duration(seconds: 30),
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  final Dio _dio;
  final Duration responseHeaderTimeout;

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
    final url = GeminiEndpoint.modelEndpoint(
      config.baseUrl,
      config.model,
      'streamGenerateContent',
      sse: true,
    );

    final body = buildRequestBody(
      config: config,
      messages: messages,
      tools: tools,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
      forceToolName: forceToolName,
    );

    final Response<ResponseBody> response;
    final requestToken = CancelToken();
    unawaited(
      cancelToken?.whenCancel.then(
        (e) => requestToken.cancel(e.error ?? e.message ?? 'cancelled'),
      ),
    );
    try {
      response = await _dio
          .post<ResponseBody>(
            url,
            options: Options(
              responseType: ResponseType.stream,
              headers: {
                ...config.transportHeaders,
                ...GeminiEndpoint.headers(
                  config.baseUrl,
                  config.authMode == 'none' ? '' : config.apiKey,
                  accept: 'text/event-stream',
                ),
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
      if (CancelToken.isCancel(e)) return;
      throw await humanizeLlmHttpError(e, authMode: config.authMode);
    } on TimeoutException {
      if (cancelToken?.isCancelled ?? false) return;
      throw llmResponseTimeout(headerTimeout);
    }

    final byteStream = response.data!.stream
        .cast<List<int>>()
        .transform(
          StreamTransformer.fromBind(
            const Utf8Decoder(allowMalformed: true).bind,
          ),
        )
        .transform(const LineSplitter())
        .timeout(_streamIdleTimeout);

    final pendingData = <String>[];
    final state = _GeminiStreamState();

    try {
      await for (final line in byteStream) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          if (pendingData.isNotEmpty) {
            final event = _handleEventPayload(pendingData.join('\n'), state);
            pendingData.clear();
            for (final chunk in event.chunks) {
              yield chunk;
            }
            if (event.done) break;
          }
          continue;
        }
        if (!trimmed.startsWith('data:')) continue;
        final payload = trimmed.substring(5).trim();
        if (payload.startsWith('[DONE]')) {
          if (pendingData.isNotEmpty) {
            final event = _handleEventPayload(pendingData.join('\n'), state);
            for (final chunk in event.chunks) {
              yield chunk;
            }
          }
          pendingData.clear();
          break;
        }
        if (pendingData.isEmpty) {
          final decoded = _tryDecodeJson(payload);
          if (decoded != null) {
            final event = _handleParsedEvent(decoded, state);
            for (final chunk in event.chunks) {
              yield chunk;
            }
            continue;
          }
        }
        pendingData.add(payload);
      }
      if (pendingData.isNotEmpty) {
        final event = _handleEventPayload(pendingData.join('\n'), state);
        for (final chunk in event.chunks) {
          yield chunk;
        }
      }
      if (cancelToken?.isCancelled ?? false) return;
      if (state.finishReason == null) {
        throw StateError('Gemini 响应流在完成前中断，请重试。');
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      throw await humanizeLlmHttpError(e, authMode: config.authMode);
    } on TimeoutException {
      if (cancelToken?.isCancelled ?? false) return;
      throw llmResponseTimeout(_streamIdleTimeout, headers: false);
    }
  }

  /// Builds the Gemini `generateContent` / `streamGenerateContent` request body.
  static Map<String, dynamic> buildRequestBody({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
  }) {
    final systemParts = <Map<String, dynamic>>[];
    final contents = <Map<String, dynamic>>[];
    final toolCallsById = <String, ({String name, String? wireId})>{};
    final functionResponses = <String, Map<String, dynamic>>{};
    final multimodalToolResults = ModelCatalog.normalizeId(
      config.model,
    ).startsWith('gemini-3');
    var seenNonSystem = false;

    for (final msg in messages) {
      final rawCalls = [
        for (final part in msg.responseOutputItems)
          if (part['functionCall'] is Map) part['functionCall'] as Map,
      ];
      for (final call in msg.toolCalls) {
        final id = call.id;
        final name = call.name;
        if (id != null && id.isNotEmpty && name != null && name.isNotEmpty) {
          toolCallsById[id] = (
            name: name,
            wireId: rawCalls.isEmpty
                ? id
                : rawCalls[call.index]['id'] as String?,
          );
        }
      }

      if (msg.role == MessageRole.system) {
        final text = msg.content.trim();
        if (text.isEmpty) continue;
        if (!seenNonSystem) {
          systemParts.add({'text': text});
        } else {
          _appendContentParts(contents, 'user', [
            {'text': text},
          ]);
        }
        continue;
      }

      seenNonSystem = true;
      switch (msg.role) {
        case MessageRole.user:
          if (multimodalToolResults && msg.isToolImageObservation) {
            final response = functionResponses[msg.toolImageCallId];
            if (response == null) {
              throw StateError(
                'Gemini 工具截图缺少同批次的 functionResponse：${msg.toolImageCallId}',
              );
            }
            final result = response['response'] as Map<String, dynamic>;
            if (msg.content.isNotEmpty) {
              result['result'] = '${result['result']}\n\n${msg.content}';
            }
            if (msg.imageFileIds.isNotEmpty) {
              throw StateError('Gemini 工具截图需要内联图片数据，不能使用其他服务的 file_id。');
            }
            if (msg.imageDataUrls.isNotEmpty) {
              response['parts'] = [
                for (final url in msg.imageDataUrls) _toolImagePart(url),
              ];
            }
            break;
          }
          functionResponses.clear();
          final parts = <Map<String, dynamic>>[
            if (msg.content.isNotEmpty) {'text': msg.content},
            for (final url in msg.imageDataUrls) _imageUrlToGeminiPart(url),
          ];
          if (parts.isNotEmpty) {
            _appendContentParts(contents, 'user', parts);
          }
        case MessageRole.assistant:
          functionResponses.clear();
          if (msg.responseOutputItems.isNotEmpty) {
            _appendContentParts(contents, 'model', msg.responseOutputItems);
            break;
          }
          final parts = <Map<String, dynamic>>[];
          if (msg.reasoningContent != null &&
              msg.reasoningContent!.isNotEmpty) {
            parts.add({'text': msg.reasoningContent, 'thought': true});
          }
          if (msg.content.isNotEmpty) {
            parts.add({'text': msg.content});
          }
          for (final call in msg.toolCalls) {
            final name = call.name ?? '';
            if (name.isEmpty) continue;
            parts.add({
              'functionCall': {
                if (call.id != null) 'id': call.id,
                'name': name,
                'args': _decodeToolArgs(call.argumentsJson),
              },
            });
          }
          if (parts.isNotEmpty) {
            _appendContentParts(contents, 'model', parts);
          }
        case MessageRole.tool:
          final callId = msg.toolCallId ?? '';
          final call = toolCallsById[callId];
          if (call == null) {
            throw StateError('工具结果缺少对应的 Gemini functionCall：$callId');
          }
          final response = <String, dynamic>{
            if (call.wireId != null) 'id': call.wireId,
            'name': call.name,
            'response': <String, dynamic>{'result': msg.content},
          };
          functionResponses[callId] = response;
          _appendContentParts(contents, 'user', [
            {'functionResponse': response},
          ]);
        case MessageRole.system:
          break;
      }
    }

    if (contents.isEmpty) {
      contents.add({
        'role': 'user',
        'parts': [
          {'text': ''},
        ],
      });
    }

    final body = <String, dynamic>{'contents': contents};

    if (systemParts.isNotEmpty) {
      body['systemInstruction'] = {'parts': systemParts};
    }

    if (LlmRequestPolicy.canUseTools(config, tools)) {
      body['tools'] = [
        {
          'functionDeclarations': [
            for (final tool in tools!)
              {
                'name': tool.name,
                'description': tool.description,
                'parametersJsonSchema': tool.parameters,
              },
          ],
        },
      ];
      final force = forceToolName?.trim() ?? '';
      if (force == kToolChoiceRequired) {
        body['toolConfig'] = {
          'functionCallingConfig': {'mode': 'ANY'},
        };
      } else if (force.isNotEmpty) {
        body['toolConfig'] = {
          'functionCallingConfig': {
            'mode': 'ANY',
            'allowedFunctionNames': [force],
          },
        };
      } else {
        body['toolConfig'] = {
          'functionCallingConfig': {'mode': 'AUTO'},
        };
      }
    }

    final generationConfig = <String, dynamic>{
      if (config.maxOutputTokens != null)
        'maxOutputTokens': config.maxOutputTokens,
    };
    if (thinking != null &&
        ModelCatalog.supportsGeminiThinkingConfig(config.model)) {
      final normalizedModel = ModelCatalog.normalizeId(config.model);
      final isPro = normalizedModel.contains('-pro');
      if (normalizedModel.startsWith('gemini-3')) {
        final minimalSupported =
            normalizedModel.startsWith('gemini-3-flash') ||
            normalizedModel.startsWith('gemini-3.1-flash-lite') ||
            normalizedModel.startsWith('gemini-3.5-flash-lite') ||
            normalizedModel.startsWith('gemini-3.6-flash');
        final lowLevel =
            normalizedModel.startsWith('gemini-3.1-flash-lite-image')
            ? 'minimal'
            : 'low';
        generationConfig['thinkingConfig'] = {
          'includeThoughts': thinking,
          'thinkingLevel': thinking
              ? reasoningEffort == ReasoningEffort.low
                    ? lowLevel
                    : 'high'
              : minimalSupported
              ? 'minimal'
              : 'low',
        };
      } else if (thinking) {
        generationConfig['thinkingConfig'] = {
          'includeThoughts': true,
          'thinkingBudget': config.maxOutputTokens == null
              ? _thinkingBudgetFor(reasoningEffort)
              : _thinkingBudgetFor(
                  reasoningEffort,
                ).clamp(0, config.maxOutputTokens! - 1),
        };
      } else if (isPro) {
        // Gemini Pro models cannot set thinkingBudget to 0; hide thoughts only.
        generationConfig['thinkingConfig'] = {'includeThoughts': false};
      } else {
        generationConfig['thinkingConfig'] = {'thinkingBudget': 0};
      }
    }
    if (generationConfig.isNotEmpty) {
      body['generationConfig'] = generationConfig;
    }

    return body;
  }

  static int _thinkingBudgetFor(ReasoningEffort? effort) => switch (effort) {
    ReasoningEffort.minimal || ReasoningEffort.low => 2048,
    ReasoningEffort.medium || ReasoningEffort.high || null => 8192,
    ReasoningEffort.xhigh || ReasoningEffort.max => 24576,
  };

  static void _appendContentParts(
    List<Map<String, dynamic>> contents,
    String role,
    List<Map<String, dynamic>> newParts,
  ) {
    if (newParts.isEmpty) return;
    if (contents.isNotEmpty && contents.last['role'] == role) {
      final existingParts = contents.last['parts'] as List<dynamic>;
      existingParts.addAll(newParts);
      return;
    }
    contents.add({
      'role': role,
      'parts': List<Map<String, dynamic>>.of(newParts),
    });
  }

  static Map<String, dynamic> _imageUrlToGeminiPart(String url) {
    final trimmed = url.trim();
    if (trimmed.startsWith('data:')) {
      final comma = trimmed.indexOf(',');
      if (comma > 5) {
        final header = trimmed.substring(5, comma);
        final data = trimmed.substring(comma + 1);
        final mime = header.split(';').first.trim();
        return {
          'inlineData': {
            'mimeType': mime.isEmpty ? 'image/png' : mime,
            'data': data,
          },
        };
      }
    }
    return {
      // Public/signed HTTPS URLs are fetched by Gemini. FileData.mimeType is
      // optional; a URL (especially a signed one) does not identify its MIME.
      'fileData': {'fileUri': trimmed},
    };
  }

  static Map<String, dynamic> _decodeToolArgs(String raw) {
    if (raw.trim().isEmpty) return const {};
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  static Map<String, dynamic> _toolImagePart(String url) {
    final part = _imageUrlToGeminiPart(url);
    if (!part.containsKey('inlineData')) {
      throw StateError('Gemini functionResponse.parts 需要内联图片数据。');
    }
    return part;
  }

  Map<String, dynamic>? _tryDecodeJson(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  ({List<ChatChunk> chunks, bool done}) _handleEventPayload(
    String payload,
    _GeminiStreamState state,
  ) {
    final trimmed = payload.trim();
    if (trimmed.startsWith('[DONE]')) return (chunks: const [], done: true);
    final json = _tryDecodeJson(trimmed);
    if (json == null) throw const FormatException('Gemini SSE 事件不是有效 JSON 对象');
    return _handleParsedEvent(json, state);
  }

  ({List<ChatChunk> chunks, bool done}) _handleParsedEvent(
    Map<String, dynamic> json,
    _GeminiStreamState state,
  ) {
    final streamError = _streamErrorMessage(json);
    if (streamError != null) {
      throw Exception('生成失败：$streamError');
    }

    final usage = LlmUsage.fromGemini(json['usageMetadata']);
    final candidates = json['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      final blockReason = _promptBlockReason(json['promptFeedback']);
      if (blockReason != null) {
        throw Exception('生成被安全策略拦截：$blockReason');
      }
      return (
        chunks: usage == null ? const [] : [ChatChunk(usage: usage)],
        done: false,
      );
    }

    final candidate = candidates.first;
    if (candidate is! Map) {
      return (
        chunks: usage == null ? const [] : [ChatChunk(usage: usage)],
        done: false,
      );
    }

    final contentBuf = StringBuffer();
    final reasoningBuf = StringBuffer();

    final content = candidate['content'];
    if (content is Map) {
      final parts = content['parts'];
      if (parts is List) {
        for (final rawPart in parts) {
          if (rawPart is! Map) continue;
          final part = Map<String, dynamic>.from(rawPart);
          state.rawModelParts.add(part);

          final isThought = part['thought'] == true;
          final text = part['text'];
          if (text is String && text.isNotEmpty) {
            if (isThought) {
              reasoningBuf.write(text);
            } else {
              contentBuf.write(text);
            }
          }

          final fnCall = part['functionCall'];
          if (fnCall is Map) {
            final name = fnCall['name'] as String;
            final args = fnCall['args'] as Map? ?? const {};
            final index = state.nextToolCallIndex++;
            final id =
                (fnCall['id'] as String?) ?? 'gemini_call_${index}_$name';
            state.toolCalls.add(
              ToolCall(
                index: index,
                id: id,
                name: name,
                argumentsJson: jsonEncode(args),
              ),
            );
          }
        }
      }
    }

    final rawFinish = candidate['finishReason'] as String?;
    final finishReason = _mapFinishReason(
      rawFinish,
      sawFunctionCall: state.toolCalls.isNotEmpty,
    );
    if (finishReason != null) state.finishReason = finishReason;
    final citations = _extractCitations(candidate['groundingMetadata']);

    return (
      chunks: [
        ChatChunk(
          contentDelta: contentBuf.isEmpty ? null : contentBuf.toString(),
          reasoningDelta: reasoningBuf.isEmpty ? null : reasoningBuf.toString(),
          toolCalls: finishReason == 'tool_calls'
              ? List.of(state.toolCalls)
              : null,
          finishReason: finishReason,
          citations: citations,
          responseOutputItems: state.rawModelParts.isNotEmpty
              ? List<Map<String, dynamic>>.of(state.rawModelParts)
              : null,
          usage: usage,
        ),
      ],
      done: false,
    );
  }

  String? _mapFinishReason(String? raw, {required bool sawFunctionCall}) {
    if (raw == null || raw.isEmpty) return null;
    return switch (raw.toUpperCase()) {
      'STOP' => sawFunctionCall ? 'tool_calls' : 'stop',
      'MAX_TOKENS' => 'length',
      'SAFETY' ||
      'RECITATION' ||
      'BLOCKLIST' ||
      'PROHIBITED_CONTENT' ||
      'SPII' ||
      'IMAGE_SAFETY' ||
      'IMAGE_PROHIBITED_CONTENT' ||
      'IMAGE_RECITATION' => 'content_filter',
      _ => throw StateError('Gemini 未完成答复：$raw'),
    };
  }

  List<Citation>? _extractCitations(dynamic groundingMetadata) {
    if (groundingMetadata is! Map) return null;
    final chunks = groundingMetadata['groundingChunks'];
    if (chunks is! List || chunks.isEmpty) return null;
    final citations = <Citation>[];
    for (final item in chunks) {
      if (item is! Map) continue;
      final web = item['web'];
      if (web is! Map) continue;
      final uri = (web['uri'] as String?)?.trim() ?? '';
      if (uri.isEmpty) continue;
      final title = (web['title'] as String?)?.trim() ?? uri;
      citations.add(
        Citation(
          index: citations.length + 1,
          title: title.isEmpty ? uri : title,
          url: uri,
          snippet: '',
        ),
      );
    }
    return citations.isEmpty ? null : citations;
  }

  String? _promptBlockReason(dynamic promptFeedback) {
    if (promptFeedback is! Map) return null;
    final reason = promptFeedback['blockReason'];
    if (reason is String && reason.trim().isNotEmpty) return reason.trim();
    return null;
  }

  String? _streamErrorMessage(Map<String, dynamic> payload) {
    final error = payload['error'];
    if (error is Map) {
      final message = error['message'] ?? error['detail'] ?? error['status'];
      if (message is String && message.trim().isNotEmpty) {
        return clipLlmErrorMessage(message);
      }
    }
    if (error is String && error.trim().isNotEmpty) {
      return clipLlmErrorMessage(error);
    }
    return null;
  }
}

class _GeminiStreamState {
  int nextToolCallIndex = 0;
  String? finishReason;
  final List<ToolCall> toolCalls = [];
  final List<Map<String, dynamic>> rawModelParts = [];
}
