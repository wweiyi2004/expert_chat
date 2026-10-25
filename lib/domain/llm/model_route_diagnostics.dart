import 'llm_provider.dart';

/// Transport metadata only. Never stores credentials, server bodies or prompts.
class ModelRouteEvent {
  const ModelRouteEvent({
    required this.at,
    required this.model,
    required this.channel,
    required this.outcome,
    required this.elapsed,
    this.statusCode,
    this.session,
  });
  final DateTime at;
  final String model, channel, outcome;
  final Duration elapsed;
  final int? statusCode;
  final String? session;
}

class ModelRouteDiagnostics {
  final _events = <ModelRouteEvent>[];
  final _listeners = <void Function()>[];
  List<ModelRouteEvent> get events => List.unmodifiable(_events);
  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void record(
    LlmConfig config,
    String outcome,
    Duration elapsed, {
    int? statusCode,
  }) {
    _events.add(
      ModelRouteEvent(
        at: DateTime.now(),
        model: config.model,
        channel: config.profileId ?? 'unregistered',
        outcome: outcome,
        elapsed: elapsed,
        statusCode: statusCode,
        session: config.routingSessionId,
      ),
    );
    if (_events.length > 200) _events.removeRange(0, _events.length - 200);
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {
        /* Diagnostics cannot fail a model call. */
      }
    }
  }

  void clear() {
    _events.clear();
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {
        /* Read-only observers are best effort. */
      }
    }
  }
}
