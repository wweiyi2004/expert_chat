import 'package:dio/dio.dart';
import 'llm_provider.dart';
import 'llm_http_errors.dart';
import 'model_route_diagnostics.dart';
import 'model_credentials_unavailable.dart';

class PrioritizedLlmProvider implements LlmProvider {
  PrioritizedLlmProvider({
    required this.delegate,
    required this.candidates,
    required this.credentials,
    this.diagnostics,
  });
  final LlmProvider delegate;
  final Future<List<LlmConfig>> Function(LlmConfig) candidates;
  final Future<LlmConfig> Function(LlmConfig) credentials;
  final ModelRouteDiagnostics? diagnostics;
  final _pinned = <String, LlmConfig>{};
  bool _canTryNext(Object error) {
    if (error is ModelCredentialsUnavailable) return true;
    final status = error is LlmHttpException
        ? error.statusCode
        : error is DioException
        ? error.response?.statusCode
        : null;
    return [
          401,
          402,
          403,
          404,
          408,
          429,
          500,
          502,
          503,
          504,
        ].contains(status) ||
        error is DioException &&
            error.type == DioExceptionType.connectionTimeout;
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
    final key = config.routingSessionId == null
        ? null
        : '${config.routingSessionId}:${config.model}';
    var pinned = key == null ? null : _pinned[key];
    if (config.lockProfile && pinned?.profileId != config.profileId) {
      if (key != null) _pinned.remove(key);
      pinned = null;
    }
    if (key != null &&
        pinned != null &&
        pinned.profileId == config.profileId &&
        pinned.model == config.model &&
        (pinned.baseUrl != config.baseUrl ||
            pinned.apiFormat != config.apiFormat ||
            pinned.authMode != config.authMode)) {
      // Explicit edit of this same channel: apply the caller's exact transport,
      // never re-enumerate other channels or silently change profile identity.
      pinned = config.copyWith(modelFallbacks: const []);
      _pinned[key] = pinned;
    }
    // Explicit API-key rotation is not channel failover. The task runner has
    // observed the accepted profile's credential epoch at a full tool boundary;
    // keep that same host and route identity while using its new durable key.
    if (key != null &&
        pinned != null &&
        pinned.authMode == 'apiKey' &&
        config.authMode == 'apiKey' &&
        pinned.profileId == config.profileId &&
        pinned.baseUrl == config.baseUrl &&
        pinned.model == config.model &&
        pinned.apiKey != config.apiKey) {
      pinned = pinned.copyWith(apiKey: config.apiKey);
      _pinned[key] = pinned;
    }
    // Channel failover must never silently choose a different model. A model
    // routing group is a separate runner decision at a complete tool boundary.
    final options = pinned != null
        ? [
            // Pin transport, not stale request budgets. The runner supplies its
            // newly bounded config at a complete round boundary for this same
            // accepted profile; clients still passing the original failed
            // profile keep the pinned channel's own bounds.
            if (pinned.profileId == config.profileId)
              config.copyWith(
                baseUrl: pinned.baseUrl,
                apiFormat: pinned.apiFormat,
                authMode: pinned.authMode,
                apiKey: pinned.apiKey,
                modelFallbacks: const [],
              )
            else
              pinned,
          ]
        : (await candidates(config))
              .where(
                (candidate) =>
                    candidate.model == config.model &&
                    (!config.lockProfile ||
                        candidate.profileId == config.profileId),
              )
              .toList();
    if (options.isEmpty) throw StateError('当前模型没有可用渠道：${config.model}');
    for (var index = 0; index < options.length; index++) {
      var emitted = false;
      var credentialReady = false;
      final timer = Stopwatch()..start();
      try {
        if (cancelToken?.isCancelled == true) return;
        final selected = (await credentials(options[index])).copyWith(
          responseHeaderTimeout: config.responseHeaderTimeout,
          clearResponseHeaderTimeout: config.responseHeaderTimeout == null,
        );
        if (cancelToken?.isCancelled == true) return;
        credentialReady = true;
        await for (final chunk in delegate.streamChat(
          config: selected,
          messages: messages,
          tools: tools,
          thinking: thinking,
          reasoningEffort: reasoningEffort,
          forceToolName: forceToolName,
          cancelToken: cancelToken,
        )) {
          if (!emitted) {
            emitted = true;
            diagnostics?.record(selected, 'accepted', timer.elapsed);
            if (key != null) {
              _pinned[key] = selected;
              if (_pinned.length > 256) _pinned.remove(_pinned.keys.first);
            }
            yield ChatChunk(actualConfig: selected);
          }
          yield chunk;
        }
        if (!emitted) {
          diagnostics?.record(options[index], 'empty', timer.elapsed);
        }
        return;
      } catch (error) {
        final status = error is LlmHttpException
            ? error.statusCode
            : error is DioException
            ? error.response?.statusCode
            : null;
        diagnostics?.record(
          options[index],
          cancelToken?.isCancelled == true
              ? 'cancelled'
              : emitted
              ? 'interrupted'
              : error is ModelCredentialsUnavailable
              ? 'activation_missing:${error.reason}'
              : !credentialReady
              ? 'credential_refresh_failed'
              : 'failed',
          timer.elapsed,
          statusCode: status,
        );
        // Never move an accepted stream or its tool continuations to another host.
        if (emitted ||
            pinned != null ||
            index == options.length - 1 ||
            !(_canTryNext(error) ||
                (!credentialReady &&
                    error is DioException &&
                    error.type != DioExceptionType.cancel)) ||
            cancelToken?.isCancelled == true) {
          rethrow;
        }
      }
    }
  }
}
