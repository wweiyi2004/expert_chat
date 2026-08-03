import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../data/models.dart';
import 'llm_provider.dart';

/// OpenAI-compatible **Responses API** client (`POST /responses`).
///
/// Used for DeepSeek hosted `web_search` (and client `function` tools) when
/// [LlmConfig.useServerWebSearch] is true. Chat Completions stays on
/// [OpenAiCompatibleProvider].
class ResponsesApiProvider implements LlmProvider {
  ResponsesApiProvider({
    Dio? dio,
    this.responseHeaderTimeout = const Duration(seconds: 30),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
             ),
           );

  final Dio _dio;
  final Duration responseHeaderTimeout;

  static const _streamIdleTimeout = Duration(seconds: 90);
  static const _maxErrorBodyBytes = 64 * 1024;
  static const _uuid = Uuid();

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    final url =
        '${config.baseUrl.replaceAll(RegExp(r"/+$"), "")}/responses';

    final built = _buildRequest(
      config: config,
      messages: messages,
      tools: tools,
      thinking: thinking,
    );

    final Response<ResponseBody> response;
    try {
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
            data: jsonEncode(built),
            cancelToken: cancelToken,
          )
          .timeout(responseHeaderTimeout);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      throw await _humanizeError(e);
    } on TimeoutException {
      if (cancelToken?.isCancelled ?? false) return;
      throw Exception(
        '响应超时：服务端在 ${responseHeaderTimeout.inSeconds} 秒内没有开始返回数据，'
        '请检查网络或稍后重试。',
      );
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

    // Responses SSE uses `event:` + `data:` pairs (not Chat Completions'
    // bare `data:` lines). Buffer until a blank line ends the event.
    String? pendingEvent;
    final pendingData = <String>[];
    final outputItems = <Map<String, dynamic>>[];
    final functionDrafts = <String, _FunctionCallDraft>{};
    final citations = <Citation>[];
    final seenCitationUrls = <String>{};
    // Stable activity ids per output item so searching → completed updates
    // the same search panel row.
    final searchActivityIds = <String, String>{};
    var sawFunctionCall = false;
    var terminal = false;

    try {
      await for (final line in byteStream) {
        if (line.isEmpty) {
          if (pendingData.isEmpty && pendingEvent == null) continue;
          final payload = pendingData.join('\n');
          final eventType = pendingEvent;
          pendingEvent = null;
          pendingData.clear();
          if (payload.isEmpty) continue;

          final json = _tryDecodeJson(payload);
          if (json == null) continue;

          for (final chunk in _handleEvent(
            eventType: eventType,
            json: json,
            outputItems: outputItems,
            functionDrafts: functionDrafts,
            citations: citations,
            seenCitationUrls: seenCitationUrls,
            searchActivityIds: searchActivityIds,
            onFunctionCall: () => sawFunctionCall = true,
          )) {
            yield chunk;
          }

          final type = eventType ?? json['type'] as String?;
          if (type == 'response.completed' ||
              type == 'response.incomplete' ||
              type == 'response.failed') {
            terminal = true;
            if (type == 'response.failed') {
              final err = json['response'] is Map
                  ? (json['response'] as Map)['error']
                  : json['error'];
              final message = _errorFromDynamic(err) ?? 'Responses 请求失败';
              throw Exception(message);
            }
            break;
          }
          continue;
        }

        if (line.startsWith('event:')) {
          pendingEvent = line.substring(6).trim();
          continue;
        }
        if (line.startsWith('data:')) {
          pendingData.add(line.substring(5).trimLeft());
          continue;
        }
      }

      // Flush a trailing event if the server closed without a blank line.
      if (!terminal && (pendingData.isNotEmpty || pendingEvent != null)) {
        final payload = pendingData.join('\n');
        final json = _tryDecodeJson(payload);
        if (json != null) {
          for (final chunk in _handleEvent(
            eventType: pendingEvent,
            json: json,
            outputItems: outputItems,
            functionDrafts: functionDrafts,
            citations: citations,
            seenCitationUrls: seenCitationUrls,
            searchActivityIds: searchActivityIds,
            onFunctionCall: () => sawFunctionCall = true,
          )) {
            yield chunk;
          }
        }
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      throw await _humanizeError(e);
    } on TimeoutException {
      if (cancelToken?.isCancelled ?? false) return;
      throw Exception(
        '响应超时：服务端在 ${_streamIdleTimeout.inSeconds} 秒内没有返回数据，'
        '请检查网络或稍后重试。',
      );
    }

    if (sawFunctionCall) {
      final calls = functionDrafts.values
          .map((d) => d.toToolCall())
          .where((c) => (c.name ?? '').isNotEmpty)
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      yield ChatChunk(
        toolCalls: calls.isEmpty ? null : calls,
        finishReason: 'tool_calls',
        citations: citations.isEmpty ? null : List.unmodifiable(citations),
        responseOutputItems: List<Map<String, dynamic>>.unmodifiable(
          outputItems.map((e) => Map<String, dynamic>.from(e)),
        ),
      );
    } else {
      yield ChatChunk(
        finishReason: 'stop',
        citations: citations.isEmpty ? null : List.unmodifiable(citations),
        responseOutputItems: outputItems.isEmpty
            ? null
            : List<Map<String, dynamic>>.unmodifiable(
                outputItems.map((e) => Map<String, dynamic>.from(e)),
              ),
      );
    }
  }

  Map<String, dynamic> _buildRequest({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
  }) {
    final instructions = StringBuffer();
    final input = <Map<String, dynamic>>[];

    for (final message in messages) {
      if (message.responseOutputItems.isNotEmpty) {
        for (final item in message.responseOutputItems) {
          input.add(Map<String, dynamic>.from(item));
        }
        continue;
      }

      switch (message.role) {
        case MessageRole.system:
          if (message.content.trim().isNotEmpty) {
            if (instructions.isNotEmpty) instructions.writeln();
            instructions.write(message.content);
          }
        case MessageRole.user:
          input.add({
            'type': 'message',
            'role': 'user',
            'content': message.content,
          });
        case MessageRole.assistant:
          if (message.reasoningContent != null &&
              message.reasoningContent!.trim().isNotEmpty) {
            input.add({
              'type': 'reasoning',
              'content': [
                {
                  'type': 'reasoning_text',
                  'text': message.reasoningContent,
                },
              ],
            });
          }
          if (message.toolCalls.isNotEmpty) {
            for (final call in message.toolCalls) {
              input.add({
                'type': 'function_call',
                'call_id': call.id ?? 'call_${call.index}',
                'name': call.name ?? '',
                'arguments': call.argumentsJson,
              });
            }
          } else if (message.content.isNotEmpty) {
            input.add({
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': message.content},
              ],
            });
          }
        case MessageRole.tool:
          input.add({
            'type': 'function_call_output',
            'call_id': message.toolCallId ?? '',
            'output': message.content,
          });
      }
    }

    final body = <String, dynamic>{
      'model': config.model,
      'stream': true,
      if (instructions.isNotEmpty) 'instructions': instructions.toString(),
      if (input.isNotEmpty) 'input': input,
    };

    if (thinking != null) {
      body['reasoning'] = {
        'effort': thinking ? 'high' : 'none',
      };
    }

    final toolList = <Map<String, dynamic>>[];
    if (config.useServerWebSearch) {
      toolList.add({'type': 'web_search'});
    }
    if (tools != null && tools.isNotEmpty && config.capabilities.supportsTools) {
      for (final tool in tools) {
        // Client web_search is replaced by the hosted tool when server search
        // is on; keep fetch_url / generate_image as functions.
        if (config.useServerWebSearch && tool.name == 'web_search') continue;
        toolList.add({
          'type': 'function',
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        });
      }
    }
    if (toolList.isNotEmpty) {
      body['tools'] = toolList;
      if (config.useServerWebSearch && config.forceServerWebSearch) {
        body['tool_choice'] = {'type': 'web_search'};
      } else {
        body['tool_choice'] = 'auto';
      }
    }

    if (body['input'] == null && body['instructions'] == null) {
      body['input'] = ' ';
    }
    return body;
  }

  List<ChatChunk> _handleEvent({
    required String? eventType,
    required Map<String, dynamic> json,
    required List<Map<String, dynamic>> outputItems,
    required Map<String, _FunctionCallDraft> functionDrafts,
    required List<Citation> citations,
    required Set<String> seenCitationUrls,
    required Map<String, String> searchActivityIds,
    required void Function() onFunctionCall,
  }) {
    final type = eventType ?? json['type'] as String? ?? '';
    final out = <ChatChunk>[];

    switch (type) {
      case 'response.reasoning_text.delta':
        final delta = json['delta'] as String?;
        if (delta != null && delta.isNotEmpty) {
          out.add(ChatChunk(reasoningDelta: delta));
        }
      case 'response.output_text.delta':
        final delta = json['delta'] as String?;
        if (delta != null && delta.isNotEmpty) {
          out.add(ChatChunk(contentDelta: delta));
        }
      case 'response.function_call_arguments.delta':
        onFunctionCall();
        final itemId = json['item_id'] as String? ?? '';
        final delta = json['delta'] as String? ?? '';
        final draft = functionDrafts.putIfAbsent(
          itemId,
          () => _FunctionCallDraft(index: functionDrafts.length),
        );
        draft.arguments.write(delta);
      case 'response.function_call_arguments.done':
        onFunctionCall();
        final itemId = json['item_id'] as String? ?? '';
        final draft = functionDrafts.putIfAbsent(
          itemId,
          () => _FunctionCallDraft(index: functionDrafts.length),
        );
        final args = json['arguments'] as String?;
        if (args != null && args.isNotEmpty && draft.arguments.isEmpty) {
          draft.arguments.write(args);
        }
        draft.name ??= json['name'] as String?;
        draft.callId ??= json['call_id'] as String?;
      case 'response.output_item.added':
      case 'response.output_item.done':
        final item = json['item'];
        if (item is Map<String, dynamic>) {
          _upsertOutputItem(outputItems, item);
          final itemType = item['type'] as String?;
          if (itemType == 'function_call') {
            onFunctionCall();
            final itemId = item['id'] as String? ?? '';
            final draft = functionDrafts.putIfAbsent(
              itemId,
              () => _FunctionCallDraft(index: functionDrafts.length),
            );
            draft.callId ??= item['call_id'] as String?;
            draft.name ??= item['name'] as String?;
            final args = item['arguments'] as String?;
            if (args != null &&
                args.isNotEmpty &&
                draft.arguments.isEmpty) {
              draft.arguments.write(args);
            }
          }
          if (itemType == 'web_search_call' && type == 'response.output_item.done') {
            final activity = _activityFromWebSearchItem(
              item,
              searchActivityIds,
              completed: true,
            );
            if (activity != null) out.add(ChatChunk(serverSearchActivity: activity));
            _collectCitationsFromWebSearch(item, citations, seenCitationUrls);
          }
          if (itemType == 'message') {
            _collectCitationsFromMessage(item, citations, seenCitationUrls);
          }
        }
      case 'response.web_search_call.in_progress':
      case 'response.web_search_call.searching':
      case 'response.web_search_call.completed':
        final itemId = json['item_id'] as String? ??
            json['output_index']?.toString() ??
            type;
        final query = _queryFromWebSearchEvent(json);
        final id = searchActivityIds.putIfAbsent(itemId, _uuid.v4);
        final completed = type == 'response.web_search_call.completed';
        out.add(
          ChatChunk(
            serverSearchActivity: SearchActivity(
              id: id,
              kind: SearchActivityKind.search,
              query: query.isEmpty ? '官方联网搜索' : query,
              status: completed
                  ? SearchActivityStatus.done
                  : SearchActivityStatus.running,
              resultCount: completed
                  ? _resultCountFromWebSearchEvent(json)
                  : 0,
            ),
          ),
        );
      case 'response.completed':
      case 'response.incomplete':
        final response = json['response'];
        if (response is Map<String, dynamic>) {
          final output = response['output'];
          if (output is List) {
            for (final raw in output) {
              if (raw is Map<String, dynamic>) {
                _upsertOutputItem(outputItems, raw);
                if (raw['type'] == 'function_call') onFunctionCall();
                if (raw['type'] == 'web_search_call') {
                  _collectCitationsFromWebSearch(
                    raw,
                    citations,
                    seenCitationUrls,
                  );
                }
                if (raw['type'] == 'message') {
                  _collectCitationsFromMessage(
                    raw,
                    citations,
                    seenCitationUrls,
                  );
                }
              }
            }
          }
        }
      case 'response.failed':
        // Handled by the caller after this returns.
        break;
      default:
        break;
    }

    if (citations.isNotEmpty &&
        (type == 'response.completed' ||
            type == 'response.incomplete' ||
            type == 'response.output_item.done')) {
      out.add(ChatChunk(citations: List.unmodifiable(citations)));
    }
    return out;
  }

  static void _upsertOutputItem(
    List<Map<String, dynamic>> items,
    Map<String, dynamic> item,
  ) {
    final id = item['id'] as String?;
    if (id != null && id.isNotEmpty) {
      final index = items.indexWhere((e) => e['id'] == id);
      if (index >= 0) {
        items[index] = Map<String, dynamic>.from(item);
        return;
      }
    }
    items.add(Map<String, dynamic>.from(item));
  }

  static SearchActivity? _activityFromWebSearchItem(
    Map<String, dynamic> item,
    Map<String, String> searchActivityIds, {
    required bool completed,
  }) {
    final itemId = item['id'] as String? ?? '';
    final id = searchActivityIds.putIfAbsent(
      itemId.isEmpty ? _uuid.v4() : itemId,
      _uuid.v4,
    );
    final query = _queryFromAction(item['action']);
    return SearchActivity(
      id: id,
      kind: SearchActivityKind.search,
      query: query.isEmpty ? '官方联网搜索' : query,
      status: completed
          ? SearchActivityStatus.done
          : SearchActivityStatus.running,
      resultCount: completed ? _sourcesFromAction(item['action']).length : 0,
    );
  }

  static String _queryFromWebSearchEvent(Map<String, dynamic> json) {
    final fromAction = _queryFromAction(json['action']);
    if (fromAction.isNotEmpty) return fromAction;
    final item = json['item'];
    if (item is Map) return _queryFromAction(item['action']);
    final query = json['query'];
    return query is String ? query.trim() : '';
  }

  static int _resultCountFromWebSearchEvent(Map<String, dynamic> json) {
    final fromAction = _sourcesFromAction(json['action']);
    if (fromAction.isNotEmpty) return fromAction.length;
    final item = json['item'];
    if (item is Map) return _sourcesFromAction(item['action']).length;
    final n = json['result_count'] ?? json['resultCount'];
    if (n is num) return n.toInt();
    return 0;
  }

  static String _queryFromAction(dynamic action) {
    if (action is! Map) return '';
    final query = action['query'];
    if (query is String && query.trim().isNotEmpty) return query.trim();
    final queries = action['queries'];
    if (queries is List) {
      return queries
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .join(' / ');
    }
    return '';
  }

  static List<({String title, String url, String snippet})> _sourcesFromAction(
    dynamic action,
  ) {
    if (action is! Map) return const [];
    final out = <({String title, String url, String snippet})>[];
    for (final key in const ['sources', 'results', 'data']) {
      final list = action[key];
      if (list is! List) continue;
      for (final raw in list) {
        if (raw is! Map) continue;
        final url = (raw['url'] as String? ?? raw['link'] as String? ?? '')
            .trim();
        if (url.isEmpty) continue;
        out.add((
          title: (raw['title'] as String? ?? raw['name'] as String? ?? url)
              .trim(),
          url: url,
          snippet: (raw['snippet'] as String? ??
                  raw['content'] as String? ??
                  '')
              .trim(),
        ));
      }
    }
    return out;
  }

  static void _collectCitationsFromWebSearch(
    Map<String, dynamic> item,
    List<Citation> citations,
    Set<String> seen,
  ) {
    for (final source in _sourcesFromAction(item['action'])) {
      if (!seen.add(source.url)) continue;
      citations.add(
        Citation(
          index: citations.length + 1,
          title: source.title,
          url: source.url,
          snippet: source.snippet,
        ),
      );
    }
  }

  static void _collectCitationsFromMessage(
    Map<String, dynamic> item,
    List<Citation> citations,
    Set<String> seen,
  ) {
    final content = item['content'];
    if (content is! List) return;
    for (final part in content) {
      if (part is! Map) continue;
      final annotations = part['annotations'];
      if (annotations is! List) continue;
      for (final raw in annotations) {
        if (raw is! Map) continue;
        final type = raw['type'] as String? ?? '';
        if (type != 'url_citation' && type != 'citation') continue;
        final url = (raw['url'] as String? ?? '').trim();
        if (url.isEmpty || !seen.add(url)) continue;
        citations.add(
          Citation(
            index: citations.length + 1,
            title: (raw['title'] as String? ?? url).trim(),
            url: url,
            snippet: (raw['snippet'] as String? ?? '').trim(),
          ),
        );
      }
    }
  }

  Map<String, dynamic>? _tryDecodeJson(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  String? _errorFromDynamic(dynamic error) {
    if (error is Map) {
      final message = error['message'] ?? error['detail'];
      if (message is String && message.trim().isNotEmpty) {
        return _clipErrorMessage(message);
      }
    }
    if (error is String && error.trim().isNotEmpty) {
      return _clipErrorMessage(error);
    }
    return null;
  }

  Future<Exception> _humanizeError(DioException e) async {
    final status = e.response?.statusCode;
    final apiMsg = await _extractApiMessage(e.response?.data);
    final detail = apiMsg == null ? '' : '：$apiMsg';
    if (status == 400) return Exception('请求有误（400）$detail');
    if (status == 401) return Exception('鉴权失败（401）：请检查 API Key 是否正确。');
    if (status == 402) return Exception('额度不足（402）：账户余额不足。');
    if (status == 404) {
      return Exception(
        '接口未找到（404）：当前 Base URL 可能不支持 Responses API（/responses）。$detail',
      );
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
      } catch (_) {}
      final trimmed = raw.trim();
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

class _FunctionCallDraft {
  _FunctionCallDraft({required this.index});

  final int index;
  String? callId;
  String? name;
  final StringBuffer arguments = StringBuffer();

  ToolCall toToolCall() => ToolCall(
    index: index,
    id: callId ?? 'call_$index',
    name: name,
    argumentsJson: arguments.toString(),
  );
}
