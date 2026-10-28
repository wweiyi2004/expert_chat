import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models.dart';
import 'llm_endpoint.dart';
import 'llm_http_errors.dart';
import 'llm_provider.dart';
import 'llm_request_policy.dart';

/// Native Anthropic Messages adapter. Signed thinking blocks stay intact during
/// tool continuations; tool calls are exposed only after message_stop.
class AnthropicMessagesProvider implements LlmProvider {
  AnthropicMessagesProvider({
    Dio? dio,
    this.responseHeaderTimeout = const Duration(seconds: 30),
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));
  final Dio _dio;
  final Duration responseHeaderTimeout;

  static Map<String, dynamic> buildRequestBody({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
  }) {
    final system = <Map<String, dynamic>>[];
    final turns = <Map<String, dynamic>>[];
    final results = <String, Map<String, dynamic>>{};
    void append(String role, List<Map<String, dynamic>> content) {
      if (content.isEmpty) return;
      if (turns.isNotEmpty && turns.last['role'] == role) {
        (turns.last['content'] as List).addAll(content);
      } else {
        turns.add({
          'role': role,
          'content': List<Map<String, dynamic>>.of(content),
        });
      }
    }

    for (final msg in messages) {
      if (msg.isEmptyAssistant) continue;
      if (msg.imageFileIds.isNotEmpty) {
        throw StateError('Anthropic Messages 需要图片字节或 URL，不能使用其他服务的 file_id。');
      }
      if (msg.role == MessageRole.system) {
        if (msg.content.isEmpty) continue;
        final part = {'type': 'text', 'text': msg.content};
        if (turns.isEmpty) {
          system.add(part);
        } else {
          append('user', [part]);
        }
        continue;
      }
      switch (msg.role) {
        case MessageRole.user:
          if (msg.isToolImageObservation) {
            final result = results[msg.toolImageCallId];
            if (result == null) throw StateError('工具截图缺少对应的 tool_result');
            (result['content'] as List).addAll(<Map<String, dynamic>>[
              if (msg.content.trim().isNotEmpty) {'type': 'text', 'text': msg.content},
              for (final url in msg.imageDataUrls) _image(url),
            ]);
          } else {
            results.clear();
            append('user', [
              if (msg.content.isNotEmpty) {'type': 'text', 'text': msg.content},
              for (final url in msg.imageDataUrls) _image(url),
            ]);
          }
        case MessageRole.assistant:
          results.clear();
          if (msg.responseOutputItems.isNotEmpty) {
            if (msg.responseOutputItems.any(
              (b) => !{
                'text',
                'thinking',
                'redacted_thinking',
                'tool_use',
              }.contains(b['type']),
            )) {
              throw StateError('不能向 Anthropic 重放其他协议的响应内容');
            }
            append('assistant', msg.responseOutputItems);
          } else {
            append('assistant', [
              if (msg.content.isNotEmpty) {'type': 'text', 'text': msg.content},
              for (final call in msg.toolCalls)
                {
                  'type': 'tool_use',
                  'id': call.id,
                  'name': call.name,
                  'input':
                      jsonDecode(
                            call.argumentsJson.isEmpty
                                ? '{}'
                                : call.argumentsJson,
                          )
                          as Map,
                },
            ]);
          }
        case MessageRole.tool:
          if (msg.toolCallId == null || msg.toolCallId!.isEmpty) {
            throw StateError('工具结果缺少调用 ID');
          }
          final result = <String, dynamic>{
            'type': 'tool_result',
            'tool_use_id': msg.toolCallId,
            'content': <Map<String, dynamic>>[
              {'type': 'text', 'text': msg.content},
            ],
          };
          results[msg.toolCallId!] = result;
          append('user', [result]);
        case MessageRole.system:
          break;
      }
    }
    final body = <String, dynamic>{
      'model': config.model,
      'stream': true,
      'max_tokens': config.maxOutputTokens ?? 8192,
      if (system.isNotEmpty) 'system': system,
      'messages': turns,
    };
    final hasTools = LlmRequestPolicy.canUseTools(config, tools);
    final force = forceToolName?.trim() ?? '';
    if (hasTools) {
      body['tools'] = [
        for (final tool in tools!)
          {
            'name': tool.name,
            'description': tool.description,
            'input_schema': tool.parameters,
          },
      ];
      body['tool_choice'] = force == kToolChoiceRequired
          ? {'type': 'any'}
          : force.isNotEmpty
          ? {'type': 'tool', 'name': force}
          : {'type': 'auto'};
    }
    // Forced tool selection and extended thinking cannot be combined. Later
    // unforced rounds can resume thinking; never send fabricated signatures.
    if (thinking == true && !(hasTools && force.isNotEmpty)) {
      final effort = reasoningEffort ?? ReasoningEffort.high;
      final adaptive = RegExp(
        r'claude-(?:opus|sonnet)-(?:4-[6-9]|[5-9])|claude-mythos',
      ).hasMatch(config.model.toLowerCase());
      if (adaptive) {
        body['thinking'] = {'type': 'adaptive'};
        body['output_config'] = {
          'effort': effort == ReasoningEffort.low ? 'low' : 'high',
        };
      } else {
        var budget = switch (effort) {
          ReasoningEffort.minimal || ReasoningEffort.low => 2048,
          ReasoningEffort.medium || ReasoningEffort.high => 8192,
          ReasoningEffort.xhigh || ReasoningEffort.max => 24576,
        };
        if (config.maxOutputTokens != null) {
          if (config.maxOutputTokens! <= 1024) {
            throw StateError('当前思考模式需要单次输出上限大于 1024 token');
          }
          budget = budget.clamp(1024, config.maxOutputTokens! - 1);
        }
        body['thinking'] = {'type': 'enabled', 'budget_tokens': budget};
        body['max_tokens'] = config.maxOutputTokens ?? budget + 8192;
      }
    } else if (thinking != null) {
      body['thinking'] = {'type': 'disabled'};
    }
    return body;
  }

  static Map<String, dynamic> _image(String url) {
    if (url.startsWith('data:')) {
      final match = RegExp(
        r'^data:(image/(?:png|jpeg|gif|webp));base64,(.+)$',
        dotAll: true,
      ).firstMatch(url);
      if (match == null) {
        throw const FormatException(
          'Anthropic 图片需要 PNG/JPEG/GIF/WebP base64 数据',
        );
      }
      return {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': match[1], 'data': match[2]},
      };
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('无效的图片 URL');
    }
    return {
      'type': 'image',
      'source': {'type': 'url', 'url': url},
    };
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
    final headerTimeout = config.responseHeaderTimeout ?? responseHeaderTimeout;
    if (cancelToken?.isCancelled ?? false) return;
    final body = buildRequestBody(
      config: config,
      messages: messages,
      tools: tools,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
      forceToolName: forceToolName,
    );
    final token = CancelToken();
    var receivedHeaders = false;
    unawaited(cancelToken?.whenCancel.then((e) => token.cancel(e.message)));
    try {
      final response = await _dio
          .post<ResponseBody>(
            LlmEndpoint.action(config.baseUrl, 'messages'),
            data: jsonEncode(body),
            onSendProgress:config.onUploadProgress,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.stream,
              headers: {
                ...config.transportHeaders,
                if (config.authMode != 'none' &&
                    config.authMode != 'kimiCode' &&
                    config.apiKey.trim().isNotEmpty)
                  'x-api-key': config.apiKey.trim(),
                if (config.authMode != 'none' &&
                    config.apiKey.trim().isNotEmpty &&
                    Uri.parse(config.baseUrl).host != 'api.anthropic.com')
                  'Authorization': 'Bearer ${config.apiKey.trim()}',
                'anthropic-version': '2023-06-01',
                'Content-Type': 'application/json',
                'Accept': 'text/event-stream',
              },
            ),
          )
          .timeout(
            headerTimeout,
            onTimeout: () {
              token.cancel('响应头等待超时');
              throw TimeoutException('响应头等待超时');
            },
          );
      receivedHeaders = true;
      final state = _MessageStream();
      final pending = <String>[];
      final lines = response.data!.stream
          .cast<List<int>>()
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 90));
      await for (final line in lines) {
        if (cancelToken?.isCancelled ?? false) return;
        if (line.isEmpty) {
          if (pending.isEmpty) continue;
          final payload = pending.join('\n');
          pending.clear();
          yield* Stream.fromIterable(state.consume(payload));
          if (state.done) return;
        } else if (line.startsWith('data:')) {
          pending.add(line.substring(5).trimLeft());
        }
      }
      if (pending.isNotEmpty) {
        yield* Stream.fromIterable(state.consume(pending.join('\n')));
      }
      if (!state.done && !(cancelToken?.isCancelled ?? false)) {
        throw StateError('Anthropic 响应流在完成前中断，请重试。');
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      throw await humanizeLlmHttpError(e, authMode: config.authMode);
    } on TimeoutException {
      if (cancelToken?.isCancelled ?? false) return;
      throw llmResponseTimeout(
        receivedHeaders ? const Duration(seconds: 90) : headerTimeout,
        headers: !receivedHeaders,
      );
    } finally {
      token.cancel('stream closed');
    }
  }
}

class _MessageStream {
  final _blocks = <int, Map<String, dynamic>>{};
  final _text = <int, StringBuffer>{};
  final _json = <int, StringBuffer>{};
  final _signatures = <int, StringBuffer>{};
  final _closed = <int>{};
  final _usage = <String, dynamic>{};
  bool done = false;
  String? _stop;

  List<ChatChunk> consume(String payload) {
    final event = jsonDecode(payload) as Map<String, dynamic>;
    final type = event['type'];
    final delta = event['delta'];
    final index = (event['index'] as num?)?.toInt();
    switch (type) {
      case 'error':
        final error = event['error'];
        throw StateError(
          'Anthropic 生成失败：${clipLlmErrorMessage(error is Map ? '${error['message'] ?? error['type']}' : '$error')}',
        );
      case 'message_start':
        final usage = event['message']?['usage'];
        if (usage is Map) _usage.addAll(Map<String, dynamic>.from(usage));
      case 'content_block_start':
        if (index == null || _blocks.containsKey(index)) {
          throw const FormatException('重复或缺失的内容块编号');
        }
        final block = Map<String, dynamic>.from(event['content_block'] as Map);
        _blocks[index] = block;
        if (block['type'] == 'text' || block['type'] == 'thinking') {
          final value = (block[block['type']] as String?) ?? '';
          _text[index] = StringBuffer(value);
          if (value.isNotEmpty) return [_delta(block['type'], value)];
        }
      case 'content_block_delta':
        final block = _blocks[index];
        if (block == null || _closed.contains(index) || delta is! Map) {
          throw const FormatException('内容增量缺少有效内容块');
        }
        switch (delta['type']) {
          case 'text_delta':
          case 'thinking_delta':
            final field = delta['type'] == 'text_delta' ? 'text' : 'thinking';
            final value = delta[field] as String;
            (_text[index!] ??= StringBuffer()).write(value);
            return [_delta(field, value)];
          case 'input_json_delta':
            (_json[index!] ??= StringBuffer()).write(
              delta['partial_json'] as String,
            );
          case 'signature_delta':
            (_signatures[index!] ??= StringBuffer(
              block['signature'] ?? '',
            )).write(delta['signature'] as String);
        }
      case 'content_block_stop':
        final block = _blocks[index];
        if (block == null || !_closed.add(index!)) {
          throw const FormatException('无效的内容块结束事件');
        }
        if (_text.containsKey(index)) {
          block[block['type'] as String] = _text[index].toString();
        }
        if (_signatures.containsKey(index)) {
          block['signature'] = _signatures[index].toString();
        }
        if (_json.containsKey(index)) {
          block['input'] = jsonDecode(_json[index].toString()) as Map;
        }
      case 'message_delta':
        if (delta is Map && delta['stop_reason'] != null) {
          _stop = delta['stop_reason'] as String;
        }
        if (event['usage'] is Map) {
          _usage.addAll(Map<String, dynamic>.from(event['usage'] as Map));
        }
      case 'message_stop':
        if (_stop == null || _closed.length != _blocks.length) {
          throw StateError('Anthropic 返回了未完成的响应');
        }
        final finish = switch (_stop) {
          'end_turn' || 'stop_sequence' => 'stop',
          'tool_use' => 'tool_calls',
          'max_tokens' || 'model_context_window_exceeded' => 'length',
          'refusal' => 'content_filter',
          _ => 'incomplete',
        };
        final ordered = _blocks.keys.toList()..sort();
        final calls = <ToolCall>[];
        for (final i in ordered) {
          final block = _blocks[i]!;
          if (block['type'] == 'tool_use') {
            if (block['id'] is! String ||
                block['name'] is! String ||
                block['input'] is! Map) {
              throw const FormatException('工具调用格式不完整');
            }
            calls.add(
              ToolCall(
                index: calls.length,
                id: block['id'] as String,
                name: block['name'] as String,
                argumentsJson: jsonEncode(block['input']),
              ),
            );
          }
        }
        if (finish == 'tool_calls' && calls.isEmpty) {
          throw const FormatException('工具结束原因缺少工具调用');
        }
        done = true;
        int count(String key) => (_usage[key] as num?)?.toInt() ?? 0;
        return [
          ChatChunk(
            finishReason: finish,
            toolCalls: finish == 'tool_calls' ? calls : null,
            responseOutputItems: [
              for (final i in ordered) Map<String, dynamic>.from(_blocks[i]!),
            ],
            usage: _usage.isEmpty
                ? null
                : LlmUsage(
                    inputTokens:
                        count('input_tokens') +
                        count('cache_read_input_tokens') +
                        count('cache_creation_input_tokens'),
                    outputTokens: count('output_tokens'),
                    cachedInputTokens: count('cache_read_input_tokens'),
                    cacheReported: _usage.containsKey(
                      'cache_read_input_tokens',
                    ),
                  ),
          ),
        ];
    }
    return const [];
  }

  ChatChunk _delta(dynamic kind, String value) => kind == 'thinking'
      ? ChatChunk(reasoningDelta: value)
      : ChatChunk(contentDelta: value);
}
