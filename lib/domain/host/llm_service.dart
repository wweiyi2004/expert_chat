import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../llm/llm_provider.dart';
import '../../features/tui_bridge/protocol.dart';
import 'wire_models.dart';
import 'llm_wire.dart';

class _ClientModelStream {
  _ClientModelStream(this.owner);
  final String owner;
  final token = CancelToken();
  final chunks = <({int sequence, Map<String, Object?> value, int bytes})>[];
  int sequence = 0, bytes = 0;
  bool done = false;
  String? error;
  Timer? expiry;
}

class HostLlmService {
  HostLlmService(this.provider);
  final LlmProvider Function() provider;
  final _streams = <String, _ClientModelStream>{};
  bool get hasActive => _streams.values.any((s) => !s.done);
  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, dynamic> p,
  ) async {
    final owner = requiredString(p, '_bridge_client_scope');
    if (method == 'host.llm.open') {
      if (_streams.values.where((s) => !s.done).length >= 16) {
        throw const BridgeFailure('busy', '辅助模型请求过多');
      }
      final id = const Uuid().v4(), stream = _ClientModelStream(owner);
      final config = decodeLlmConfig(wireMap(p['config']));
      final messages = wireRows(p['messages']).map(decodeRequest).toList();
      final tools = p['tools'] == null
          ? null
          : wireRows(p['tools']).map(decodeTool).toList();
      _streams[id] = stream;
      unawaited(
        Future<void>(() async {
          try {
            await for (final chunk in provider().streamChat(
              config: config,
              messages: messages,
              tools: tools,
              thinking: p['thinking'] as bool?,
              reasoningEffort: p['effort'] == null
                  ? null
                  : ReasoningEffort.values.byName(p['effort'] as String),
              forceToolName: p['forceTool'] as String?,
              cancelToken: stream.token,
            )) {
              if (stream.token.isCancelled) break;
              final value = encodeChunk(chunk),
                  size = utf8.encode(jsonEncode(encodeChunk(chunk))).length;
              if (stream.bytes + size > 8 * 1024 * 1024) {
                stream.token.cancel('client stream buffer exceeded');
                throw StateError('buffer exceeded');
              }
              stream.chunks.add((
                sequence: ++stream.sequence,
                value: value,
                bytes: size,
              ));
              stream.bytes += size;
            }
          } catch (_) {
            stream.error = stream.token.isCancelled
                ? '模型请求已取消'
                : '模型请求未完成，请检查所选服务和配置';
          } finally {
            stream.done = true;
            stream.expiry = Timer(
              const Duration(minutes: 1),
              () => _streams.remove(id),
            );
          }
        }),
      );
      return {'stream_id': id};
    }
    final id = requiredString(p, 'stream_id'), stream = _streams[id];
    if (stream == null || stream.owner != owner) {
      throw const BridgeFailure('not_found', '模型请求不存在或不属于此连接');
    }
    if (method == 'host.llm.cancel') {
      stream.token.cancel('client cancelled');
      return {'accepted': true};
    }
    if (method != 'host.llm.poll') {
      throw const BridgeFailure('unsupported', '未知模型操作');
    }
    final after = p['after'] as int? ?? 0;
    if (after < 0 || after > stream.sequence) {
      throw const BridgeFailure('invalid_params', '流游标无效');
    }
    while (stream.chunks.isNotEmpty && stream.chunks.first.sequence <= after) {
      stream.bytes -= stream.chunks.removeAt(0).bytes;
    }
    final chunks = stream.chunks.take(256).toList();
    final cursor = chunks.lastOrNull?.sequence ?? after;
    return {
      'chunks': chunks.map((c) => c.value).toList(),
      'cursor': cursor,
      'done': stream.done && cursor == stream.sequence,
      'error': stream.done && cursor == stream.sequence ? stream.error : null,
    };
  }

  void disconnect(String owner) {
    for (final stream in _streams.values.where((s) => s.owner == owner)) {
      stream.token.cancel('GUI disconnected');
    }
  }

  void close() {
    for (final stream in _streams.values) {
      stream.expiry?.cancel();
      stream.token.cancel('host shutdown');
    }
    _streams.clear();
  }
}
