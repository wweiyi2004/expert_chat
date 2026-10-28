import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../data/gateway_config.dart';
import 'stdio_transport.dart';
import 'computer_use_policy.dart';

const _protocolVersion = '2026-07-28';

class McpClientException implements Exception {
  const McpClientException(this.message, {this.code = 'mcp_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

class McpToolDefinition {
  const McpToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  factory McpToolDefinition.fromJson(Map<String, dynamic> json) =>
      McpToolDefinition(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        inputSchema: _stringMap(json['inputSchema']),
      );
}

class McpServerDescription {
  const McpServerDescription({
    required this.name,
    required this.version,
    required this.tools,
  });

  final String name;
  final String version;
  final List<McpToolDefinition> tools;
}

class McpToolResult {
  const McpToolResult({
    required this.content,
    required this.structuredContent,
    required this.isError,
  });

  final List<Map<String, dynamic>> content;
  final Map<String, dynamic> structuredContent;
  final bool isError;

  String get text => [
    for (final item in content)
      if (item['type'] == 'text' && item['text'] is String)
        item['text'] as String,
  ].join('\n');
}

/// Minimal modern MCP 2026-07-28 client over Streamable HTTP.
///
/// The modern protocol is stateless: every request carries protocol and client
/// metadata, so the Flutter app does not maintain an MCP session identifier.
class McpClient {
  McpClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final _browserModelPaused = <String>{};
  final _browserLeaseEpochs = <String, int>{};

  /// A user takeover invalidates already queued model operations, including
  /// those still queued after the user releases the browser. In-flight calls
  /// may finish; no old queued mutation is replayed onto the user's new page.
  void setBrowserModelPaused(String conversation, bool paused) {
    _browserLeaseEpochs[conversation] =
        (_browserLeaseEpochs[conversation] ?? 0) + 1;
    if (paused) {
      _browserModelPaused.add(conversation);
    } else {
      _browserModelPaused.remove(conversation);
    }
  }

  int _nextId = 0;
  final Map<String, StdioTransport> _local = {};
  final Map<String, String> _localOwners = {};
  final Map<String, Future<void>> _localQueues = {};
  final Map<String, int> _sessionEpochs = {};
  int _stopEpoch = 0;
  final _computer = ComputerUsePolicy();
  bool _computerBusy = false;

  Future<void> stopLocalServers() async {
    _stopEpoch++;
    _computer.reset();
    final transports = _local.values.toList();
    _local.clear();
    _localOwners.clear();
    await Future.wait(transports.map((transport) => transport.close()));
  }
  Future<void> disconnectConnection(GatewayConnection connection) async {
    final identity=connection.localProcess?.identity;
    if(identity==null)return; // HTTP transports are request-scoped.
    final keys=_local.keys.where((key){
      if(key==identity)return true;
      try{final value=jsonDecode(key);return value is List && value.firstOrNull==identity;}catch(_){return false;}
    }).toList();
    for(final key in keys){_localOwners.remove(key);await _local.remove(key)?.close();}
  }

  /// Stop only this conversation's owned browser/agent processes. Other active
  /// conversations keep their page state and pending tool requests.
  Future<void> stopLocalSession(String sessionId) async {
    _sessionEpochs[sessionId] = (_sessionEpochs[sessionId] ?? 0) + 1;
    final keys = _localOwners.entries
        .where((entry) => entry.value == sessionId)
        .map((entry) => entry.key)
        .toList();
    final closed = <Future<void>>[];
    for (final key in keys) {
      _localOwners.remove(key);
      final transport = _local.remove(key);
      if (transport != null) closed.add(transport.close());
    }
    await Future.wait(closed);
  }

  String _localKey(GatewayConnection connection) {
    final config = connection.localProcess!;
    if (!config.requiresSession) return config.identity;
    if (connection.sessionId?.isNotEmpty != true) {
      throw const McpClientException(
        '此 MCP 工具必须在所属会话中运行',
        code: 'session_required',
      );
    }
    return jsonEncode([
      config.identity,
      connection.sessionId,
      connection.agentId,
    ]);
  }

  Future<void> close() async {
    await stopLocalServers();
    _dio.close(force: true);
  }

  Future<StdioTransport> _localTransport(
    GatewayConnection connection,
    CancelToken? cancel,
  ) async {
    if (!connection.isConfigured) {
      throw const McpClientException('本地 MCP 尚未启用或配置');
    }
    final config = connection.localProcess!;
    final key = _localKey(connection);
    var transport = _local[key];
    if (transport == null || transport.isClosed) {
      _computer.reset();
      transport = StdioTransport(config);
      _local[key] = transport;
      if (config.requiresSession) _localOwners[key] = connection.sessionId!;
    }
    try {
      await transport.initialize(
        cancelToken: cancel,
        timeout: connection.config.requestTimeout,
      );
      return transport;
    } catch (error) {
      if (identical(_local[key], transport)) {
        _local.remove(key);
        _localOwners.remove(key);
      }
      await transport.close();
      throw McpClientException(
        error.toString(),
        code: 'local_connection_failed',
      );
    }
  }

  Future<McpServerDescription> discover({
    required GatewayConnection connection,
    CancelToken? cancelToken,
  }) async {
    if (connection.localProcess?.requiresSession == true) {
      // Discovery must never borrow a live conversation's browser process.
      final discoveryId = 'mcp-discovery-${++_nextId}';
      try {
        return await _discover(
          connection: connection.forSession(discoveryId),
          cancelToken: cancelToken,
        );
      } finally {
        await stopLocalSession(discoveryId);
        _sessionEpochs.remove(discoveryId);
      }
    }
    return _discover(connection: connection, cancelToken: cancelToken);
  }

  Future<McpServerDescription> _discover({
    required GatewayConnection connection,
    CancelToken? cancelToken,
  }) async {
    final discovered = connection.localProcess == null
        ? await _request(
            connection: connection,
            method: 'server/discover',
            params: const {},
            cancelToken: cancelToken,
          )
        : <String, dynamic>{
            '_meta': {
              'io.modelcontextprotocol/serverInfo': (await _localTransport(
                connection,
                cancelToken,
              )).serverInfo,
            },
          };
    final meta = _stringMap(discovered['_meta']);
    final serverInfo = _stringMap(meta['io.modelcontextprotocol/serverInfo']);
    final tools = <McpToolDefinition>[];
    String? cursor;
    final cursors = <String>{};
    do {
      final listed = await _request(
        connection: connection,
        method: 'tools/list',
        params: {'cursor': ?cursor},
        cancelToken: cancelToken,
      );
      tools.addAll([
        for (final raw
            in listed['tools'] is List
                ? listed['tools'] as List<dynamic>
                : const <dynamic>[])
          if (raw is Map)
            McpToolDefinition.fromJson(Map<String, dynamic>.from(raw)),
      ]);
      cursor = listed['nextCursor'] as String?;
      if (cursor != null && (!cursors.add(cursor) || cursors.length > 50)) {
        throw const McpClientException('MCP 工具分页无效或过多');
      }
    } while (cursor != null && cursor.isNotEmpty);
    return McpServerDescription(
      name: serverInfo['name']?.toString() ?? 'MCP Server',
      version: serverInfo['version']?.toString() ?? '?',
      tools: tools.where((tool) => tool.name.isNotEmpty).toList(),
    );
  }

  Future<McpToolResult> callTool({
    required GatewayConnection connection,
    required String name,
    required Map<String, dynamic> arguments,
    CancelToken? cancelToken,
    bool userInitiated = false,
  }) async {
    final browserModelCall =
        connection.localProcess?.isPlaywright == true && !userInitiated;
    final browserEpoch = _browserLeaseEpochs[connection.sessionId] ?? 0;
    if (browserModelCall &&
        _browserModelPaused.contains(connection.sessionId)) {
      throw const McpClientException(
        '用户正在接手浏览器，模型操作未派发',
        code: 'browser_user_takeover',
      );
    }
    if (connection.localProcess?.requiresSession == true &&
        !connection.computerUse) {
      final key = _localKey(connection);
      final epoch = _sessionEpochs[connection.sessionId] ?? 0;
      final stopEpoch = _stopEpoch;
      final previous = _localQueues[key] ?? Future<void>.value();
      final completed = Completer<void>();
      _localQueues[key] = completed.future;
      try {
        // Browser operations must retain order within one agent, even if the
        // provider emits several calls in a parallel tool batch.
        await previous;
        if (browserModelCall &&
            (_browserModelPaused.contains(connection.sessionId) ||
                browserEpoch !=
                    (_browserLeaseEpochs[connection.sessionId] ?? 0))) {
          throw const McpClientException(
            '浏览器已由用户接手，本次旧排队操作已丢弃；请重新观察',
            code: 'browser_stale_lease',
          );
        }
        if (cancelToken?.isCancelled == true ||
            stopEpoch != _stopEpoch ||
            epoch != (_sessionEpochs[connection.sessionId] ?? 0)) {
          throw const McpClientException('MCP 请求已取消', code: 'cancelled');
        }
        return await _callTool(
          connection: connection,
          name: name,
          arguments: arguments,
          cancelToken: cancelToken,
        );
      } finally {
        completed.complete();
        if (identical(_localQueues[key], completed.future)) {
          _localQueues.remove(key);
        }
      }
    }
    if (connection.computerUse) {
      if (_computerBusy) throw const McpClientException('另一个电脑操作正在执行');
      _computerBusy = true;
      try {
        if (connection.localProcess != null) {
          await _localTransport(connection, cancelToken);
        }
        final safeArgs = _computer.prepare(connection, name, arguments);
        final result = await _callTool(
          connection: connection,
          name: name,
          arguments: safeArgs,
          cancelToken: cancelToken,
        );
        if (name == 'get_window_state') {
          _computer.observed(connection, safeArgs);
        }
        if (!ComputerUsePolicy.actions.contains(name)) return result;
        // Read back the exact window after each mutation, never replay the action.
        final verificationArgs = _computer.prepare(
          connection,
          'get_window_state',
          {'pid': safeArgs['pid'], 'window_id': safeArgs['window_id']},
        );
        try {
          final after = await _callTool(
            connection: connection,
            name: 'get_window_state',
            arguments: verificationArgs,
            cancelToken: cancelToken,
          );
          _computer.observed(connection, verificationArgs);
          return McpToolResult(
            content: [
              {
                'type': 'text',
                'text': '操作已返回，以下是操作后的新观察。请据此核验结果，旧元素标识已失效。\n${result.text}',
              },
              ...after.content,
            ],
            structuredContent: after.structuredContent,
            isError: false,
          );
        } catch (_) {
          throw const McpClientException(
            '操作可能已执行，但无法核验结果。请重新观察，不要直接重试该操作。',
            code: 'outcome_unknown',
          );
        }
      } on McpClientException catch (error) {
        if (error.code.startsWith('background_') ||
            error.message.contains('background_unavailable')) {
          _computer.refused(connection, arguments);
        }
        rethrow;
      } on StateError catch (error) {
        throw McpClientException(
          error.message.toString(),
          code: 'computer_use_policy',
        );
      } finally {
        _computerBusy = false;
      }
    }
    return _callTool(
      connection: connection,
      name: name,
      arguments: arguments,
      cancelToken: cancelToken,
    );
  }

  Future<McpToolResult> _callTool({
    required GatewayConnection connection,
    required String name,
    required Map<String, dynamic> arguments,
    CancelToken? cancelToken,
  }) async {
    final result = await _request(
      connection: connection,
      method: 'tools/call',
      params: {'name': name, 'arguments': arguments},
      mcpName: name,
      cancelToken: cancelToken,
    );
    final content = <Map<String, dynamic>>[
      for (final raw
          in result['content'] is List
              ? result['content'] as List<dynamic>
              : const <dynamic>[])
        if (raw is Map) Map<String, dynamic>.from(raw),
    ];
    final callResult = McpToolResult(
      content: content,
      structuredContent: _stringMap(result['structuredContent']),
      isError: result['isError'] == true,
    );
    if (callResult.isError) {
      throw McpClientException(
        callResult.text.trim().isEmpty
            ? 'MCP 工具 $name 执行失败'
            : callResult.text.trim(),
        code: callResult.structuredContent['code']?.toString() ?? 'tool_error',
      );
    }
    return callResult;
  }

  Future<Uint8List> readBinaryResource({
    required GatewayConnection connection,
    required String uri,
    CancelToken? cancelToken,
  }) async {
    final result = await _request(
      connection: connection,
      method: 'resources/read',
      params: {'uri': uri},
      mcpName: uri,
      cancelToken: cancelToken,
    );
    final contents = result['contents'];
    if (contents is! List || contents.isEmpty || contents.first is! Map) {
      throw const McpClientException('MCP Resource 没有返回内容');
    }
    final item = Map<String, dynamic>.from(contents.first as Map);
    final blob = item['blob'];
    if (blob is String && blob.isNotEmpty) {
      try {
        return base64Decode(blob);
      } on FormatException catch (error) {
        throw McpClientException('MCP Resource Base64 无效：$error');
      }
    }
    final text = item['text'];
    if (text is String) return Uint8List.fromList(utf8.encode(text));
    throw const McpClientException('MCP Resource 既没有 blob 也没有 text');
  }

  Future<Map<String, dynamic>> _request({
    required GatewayConnection connection,
    required String method,
    required Map<String, dynamic> params,
    String? mcpName,
    CancelToken? cancelToken,
  }) async {
    final config = connection.config;
    if (!connection.isConfigured) {
      throw const McpClientException('MCP Server 尚未启用或配置');
    }
    if (connection.localProcess != null) {
      final transport = await _localTransport(connection, cancelToken);
      try {
        return await transport.request(
          method,
          params,
          cancelToken: cancelToken,
          timeout: config.requestTimeout,
        );
      } catch (error) {
        if (!transport.isAlive) {
          final key = _localKey(connection);
          if (identical(_local[key], transport)) {
            _local.remove(key);
            _localOwners.remove(key);
          }
          await transport.close();
        }
        throw McpClientException(
          error.toString(),
          code: 'local_request_failed',
        );
      }
    }
    final endpoint = _endpoint(config.normalizedBaseUrl);
    final token = await connection.resolveApiToken();
    final stampedParams = <String, dynamic>{
      ...params,
      '_meta': {
        'io.modelcontextprotocol/protocolVersion': _protocolVersion,
        'io.modelcontextprotocol/clientInfo': {
          'name': 'expert-chat',
          'version': '3.5.0',
        },
        'io.modelcontextprotocol/clientCapabilities': <String, dynamic>{},
      },
    };
    try {
      final response = await _dio.post<Object?>(
        endpoint,
        data: {
          'jsonrpc': '2.0',
          'id': 'expert-chat-${++_nextId}',
          'method': method,
          'params': stampedParams,
        },
        options: Options(
          headers: {
            ...connection.headers,
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
            'MCP-Protocol-Version': _protocolVersion,
            'Mcp-Method': method,
            'Mcp-Name': ?mcpName,
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          },
          responseType: ResponseType.json,
          connectTimeout: config.requestTimeout,
          receiveTimeout: config.requestTimeout,
          sendTimeout: config.requestTimeout,
          validateStatus: (status) => status != null && status < 500,
        ),
        cancelToken: cancelToken,
      );
      final status = response.statusCode ?? 0;
      if (status == 401 || status == 403) {
        throw const McpClientException(
          'MCP Server 鉴权失败：请检查 MCP Token',
          code: 'unauthorized',
        );
      }
      final envelope = _responseMap(response.data);
      if (status >= 400) {
        throw McpClientException(
          _rpcErrorMessage(envelope) ?? 'MCP HTTP 请求失败（$status）',
          code: 'http_error',
        );
      }
      final error = envelope['error'];
      if (error is Map) {
        throw McpClientException(
          error['message']?.toString() ?? 'MCP JSON-RPC 请求失败',
          code: error['code']?.toString() ?? 'rpc_error',
        );
      }
      final result = envelope['result'];
      if (result is Map<String, dynamic>) return result;
      if (result is Map) return Map<String, dynamic>.from(result);
      throw const McpClientException('MCP Server 返回了无效的 JSON-RPC 结果');
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      final status = error.response?.statusCode;
      if (status != null && status >= 500 && status < 600) {
        throw McpClientException(
          '文档服务暂时不可用（HTTP $status）：请检查服务器或反向代理，稍后重试。',
          code: 'service_unavailable',
        );
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw const McpClientException('MCP 请求超时：请检查服务器或增大超时时间');
      }
      if (error.type == DioExceptionType.connectionError) {
        throw const McpClientException('无法连接 MCP Server：请检查地址和网络');
      }
      final envelope = _responseMap(error.response?.data);
      throw McpClientException(
        _rpcErrorMessage(envelope) ?? 'MCP 请求失败：${error.message}',
      );
    }
  }

  static String _endpoint(String baseUrl) {
    final value = baseUrl.trim();
    return value.endsWith('/mcp') ? value : '$value/mcp';
  }

  static Map<String, dynamic> _responseMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return const {};
  }

  static String? _rpcErrorMessage(Map<String, dynamic> envelope) {
    final error = envelope['error'];
    if (error is Map && error['message'] != null) {
      return error['message'].toString();
    }
    return null;
  }
}

Map<String, dynamic> _stringMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}
