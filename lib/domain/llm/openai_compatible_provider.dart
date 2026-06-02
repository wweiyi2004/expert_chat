import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models.dart';
import 'llm_provider.dart';

/// LLM provider for any OpenAI-compatible `/chat/completions` SSE endpoint.
/// DeepSeek, OpenAI, Kimi, 智谱 etc. all share this wire format.
class OpenAiCompatibleProvider implements LlmProvider {
  OpenAiCompatibleProvider({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              // Fail fast on a dead network; no receiveTimeout so long streamed
              // answers are never cut off mid-generation.
              connectTimeout: const Duration(seconds: 30),
            ));

  final Dio _dio;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<ChatMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
  }) async* {
    final url = '${config.baseUrl.replaceAll(RegExp(r"/+$"), "")}'
        '/chat/completions';

    final body = <String, dynamic>{
      'model': config.model,
      'stream': true,
      'messages': messages
          // chain-of-thought is never sent back to the API
          .map((m) => {'role': m.role.wire, 'content': m.content})
          .toList(),
    };
    // DeepSeek V4 defaults thinking to ENABLED, so we must explicitly disable it
    // for fast normal chat (and enable it for deep-think). The `thinking` field
    // is DeepSeek-specific, so only send it for deepseek-v4 models to avoid
    // 400s from other OpenAI-compatible providers.
    if (thinking != null && config.model.startsWith('deepseek-v4')) {
      body['thinking'] = {'type': thinking ? 'enabled' : 'disabled'};
    }
    // Reasoner models reject `tools`; callers must not pass them for reasoners,
    // but guard here too so a stray tool list can't break the request.
    if (tools != null && tools.isNotEmpty && !KnownModels.isReasoner(config.model)) {
      body['tools'] = tools.map((t) => t.toJson()).toList();
      body['tool_choice'] = 'auto';
    }

    final Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
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
      );
    } on DioException catch (e) {
      throw await _humanizeError(e);
    }

    final byteStream = response.data!.stream
        .cast<List<int>>()
        .transform(StreamTransformer.fromBind(utf8.decoder.bind))
        .transform(const LineSplitter());

    await for (final line in byteStream) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trim();
      if (payload == '[DONE]') return;

      Map<String, dynamic> json;
      try {
        json = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue; // ignore keep-alive / malformed fragments
      }

      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) continue;
      final choice = choices.first as Map<String, dynamic>;
      final delta = choice['delta'] as Map<String, dynamic>?;
      final finishReason = choice['finish_reason'] as String?;
      if (delta == null) {
        if (finishReason != null) yield ChatChunk(finishReason: finishReason);
        continue;
      }

      yield ChatChunk(
        contentDelta: delta['content'] as String?,
        reasoningDelta: delta['reasoning_content'] as String?,
        toolCalls: _parseToolCalls(delta['tool_calls']),
        finishReason: finishReason,
      );
    }
  }

  List<ToolCall>? _parseToolCalls(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final out = <ToolCall>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final fn = e['function'] as Map<String, dynamic>?;
      out.add(ToolCall(
        index: (e['index'] as num?)?.toInt() ?? 0,
        id: e['id'] as String?,
        name: fn?['name'] as String?,
        argumentsJson: fn?['arguments'] as String? ?? '',
      ));
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
    if (e.type == DioExceptionType.connectionError) {
      return Exception('连接失败：请检查网络或 Base URL。');
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
        final chunks = await data.stream.toList();
        raw = utf8.decode(chunks.expand((c) => c).toList());
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
      return trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed;
    } catch (_) {
      return null;
    }
  }

  String? _messageFromMap(Map<dynamic, dynamic> map) {
    final err = map['error'];
    if (err is Map && err['message'] is String) return err['message'] as String;
    if (err is String) return err;
    if (map['message'] is String) return map['message'] as String;
    return null;
  }
}
