import 'dart:async';
import 'package:dio/dio.dart';
import '../llm/llm_provider.dart';
import 'host_client.dart';
import 'llm_wire.dart';
import 'wire_models.dart';

class HostLlmProvider implements LlmProvider {
  HostLlmProvider(this.client);
  final HostClient client;
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
    final token = cancelToken ?? CancelToken();
    if (token.isCancelled) throw token.cancelError!;
    String? streamId;
    try {
      final opened = await client.invoke('host.llm.open', {
        'config': encodeLlmConfig(config),
        'messages': messages.map(encodeRequest).toList(),
        'tools': tools?.map(encodeTool).toList(),
        'thinking': thinking,
        'effort': reasoningEffort?.name,
        'forceTool': forceToolName,
      });
      streamId = opened['stream_id'] as String;
      var cursor = 0;
      while (!token.isCancelled) {
        final response = await Future.any<Map<String, dynamic>>([
          client.invoke('host.llm.poll', {
            'stream_id': streamId,
            'after': cursor,
          }),
          token.whenCancel.then<Map<String, dynamic>>((e) => throw e),
        ]);
        for (final chunk in wireRows(response['chunks'])) {
          if (token.isCancelled) break;
          yield decodeChunk(chunk);
        }
        cursor = response['cursor'] as int;
        if (response['done'] == true) {
          if (response['error'] != null) {
            throw StateError(response['error'] as String);
          }
          break;
        }
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 50)),
          token.whenCancel.then<void>((e) => throw e),
        ]);
      }
      if (token.isCancelled) throw token.cancelError!;
    } finally {
      if (streamId != null && client.connected) {
        unawaited(
          client
              .invoke('host.llm.cancel', {'stream_id': streamId})
              .catchError((Object _) => <String, dynamic>{}),
        );
      }
    }
  }
}
