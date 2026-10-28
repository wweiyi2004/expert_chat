import 'dart:convert';

/// Only differences backed by public controller state become incremental events.
/// Snapshots remain authoritative when a stream revises earlier text.
List<({String event, Map<String, Object?> data})> bridgeSnapshotEvents(
  Map<String, Object?> before,
  Map<String, Object?> after,
) {
  final result = <({String event, Map<String, Object?> data})>[];
  void emit(String event, Map<String, Object?> data) =>
      result.add((event: event, data: data));
  Map<String, dynamic> session(Map<String, Object?> state) =>
      Map<String, dynamic>.from(state['session'] as Map? ?? {});
  final old = session(before), current = session(after);
  if (old['id'] != current['id']) return result;
  if (current['round'] != null &&
      (old['round'] != current['round'] ||
          !['running', 'approval', 'retrying'].contains(old['status']) &&
              current['status'] == 'running')) {
    emit('round.started', {
      'round': current['round'],
      'round_limit': current['round_limit'],
      'status': current['status'],
    });
  }
  if (['running', 'approval', 'retrying'].contains(old['status']) &&
      !['running', 'approval', 'retrying'].contains(current['status'])) {
    emit('round.ended', {
      'round': current['round'],
      'round_limit': current['round_limit'],
      'status': current['status'],
    });
  }
  Map<String, Map<String, Object?>> index(
    Map<String, Object?> state,
    String name,
  ) => {
    for (final row in state[name] as List? ?? [])
      if (row is Map && row['id'] is String)
        row['id'] as String: Map<String, Object?>.from(row),
  };
  final previousMessages = index(before, 'messages');
  for (final message in index(after, 'messages').values) {
    if (message['role'] != 'assistant') continue;
    final prior = previousMessages[message['id']] ?? {};
    final oldText = prior['text'] as String? ?? '';
    final text = message['text'] as String? ?? '';
    if (text.length > oldText.length && text.startsWith(oldText)) {
      emit('assistant.delta', {
        'message_id': message['id'],
        'text': text.substring(oldText.length),
      });
    }
    if ((prior['thinking'] as String? ?? '').isEmpty &&
        (message['thinking'] as String? ?? '').isNotEmpty) {
      emit('thinking.started', {'message_id': message['id']});
    }
    if ((prior['thinking'] as String? ?? '').isNotEmpty &&
        old['status'] == 'running' &&
        current['status'] != 'running') {
      emit('thinking.ended', {'message_id': message['id']});
    }
  }
  for (final category in ['steps', 'agents', 'approvals']) {
    final previous = index(before, category);
    for (final row in index(after, category).values) {
      final prior = previous[row['id']];
      if (jsonEncode(prior) == jsonEncode(row)) continue;
      if (category == 'steps') {
        emit(
          prior == null
              ? 'step.started'
              : ['done', 'failed', 'stopped'].contains(row['status'])
              ? 'step.ended'
              : 'step.updated',
          row,
        );
      } else if (category == 'agents') {
        emit('agent.updated', row);
      } else if (prior == null) {
        emit('approval.requested', row);
      }
    }
  }
  if (jsonEncode(before['changes']) != jsonEncode(after['changes'])) {
    emit('changes.updated', {'changes': after['changes']});
  }
  if(jsonEncode(old['usage'])!=jsonEncode(current['usage']))emit('usage.updated',{'usage':current['usage']});
  if (old['context_percent'] != current['context_percent']) {
    emit('context.updated', {'context_percent': current['context_percent']});
  }
  if (current['retry'] is Map &&
      jsonEncode(old['retry']) != jsonEncode(current['retry'])) {
    emit('request.retry', Map<String, Object?>.from(current['retry'] as Map));
  }
  if (current['error'] != null && old['error'] != current['error']) {
    emit('request.error', {
      'code': 'backend_error',
      'message': current['error'],
      'retryable': false,
    });
  }
  return result;
}
