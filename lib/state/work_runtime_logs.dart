import 'dart:async';
import 'dart:convert';

import '../platform/foundation.dart';
import 'package:riverpod/riverpod.dart';
import '../platform/preferences.dart';

import '../core/providers.dart';
import '../data/work_runtime_log.dart';
export '../data/work_runtime_log.dart';

final workRuntimeLogsProvider =
    NotifierProvider<WorkRuntimeLogs, List<WorkRuntimeLogEntry>>(
      WorkRuntimeLogs.new,
    );

class WorkRuntimeLogs extends Notifier<List<WorkRuntimeLogEntry>> {
  static const storageKey = 'workRuntimeLogs.v1';
  late SharedPreferences _prefs;
  Future<void> _pending = Future.value();
  Timer? _saveTimer;
  String _snapshot = '[]';
  int _sequence = 0;

  @override
  List<WorkRuntimeLogEntry> build() {
    _prefs = ref.read(sharedPrefsProvider);
    final restored = <WorkRuntimeLogEntry>[];
    try {
      final raw = _prefs.getString(storageKey);
      if (raw != null && raw.length <= 2 * 1024 * 1024) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final row in decoded.take(2000)) {
            try {
              restored.add(
                WorkRuntimeLogEntry.fromJson(
                  Map<String, dynamic>.from(row as Map),
                ),
              );
            } catch (_) {
              /* A corrupt row does not discard other sessions. */
            }
          }
        }
      }
    } catch (_) {
      /* Logs must never block starting a task. */
    }
    final retained = retainRuntimeLogs(restored, now: DateTime.now());
    _snapshot = jsonEncode(retained.map((e) => e.toJson()).toList());
    ref.onDispose(() {
      _saveTimer?.cancel();
      unawaited(_enqueueSave(_snapshot));
    });
    return retained;
  }

  void add({
    required String conversationId,
    required String phase,
    required String status,
    WorkRuntimeLogLevel level = WorkRuntimeLogLevel.info,
    String? taskId,
    String? requestId,
    String? toolCallId,
    String? toolName,
    String? model,
    String? endpoint,
    String? detail,
    String? errorType,
    int? durationMs,
    int? httpStatus,
    int? timeoutSeconds,
    Iterable<String> secrets = const [],
  }) {
    String clean(String text) => sanitizeRuntimeLogText(text, secrets: secrets);
    String? optional(String? text) => text == null ? null : clean(text);
    final now = DateTime.now();
    final entry = WorkRuntimeLogEntry(
      id: '${now.microsecondsSinceEpoch}_${_sequence++}',
      conversationId: clean(conversationId),
      timestamp: now,
      level: level,
      phase: clean(phase),
      status: clean(status),
      taskId: optional(taskId),
      requestId: optional(requestId),
      toolCallId: optional(toolCallId),
      toolName: optional(toolName),
      model: optional(model),
      host: optional(runtimeLogHost(endpoint)),
      detail: optional(detail),
      errorType: optional(errorType),
      durationMs: durationMs,
      httpStatus: httpStatus,
      timeoutSeconds: timeoutSeconds,
    );
    state = retainRuntimeLogs([...state, entry], now: now);
    _snapshot = jsonEncode(state.map((e) => e.toJson()).toList());
    _saveTimer ??= Timer(const Duration(milliseconds: 250), () {
      _saveTimer = null;
      unawaited(_enqueueSave(_snapshot));
    });
    if (level == WorkRuntimeLogLevel.error) unawaited(flush());
  }

  List<WorkRuntimeLogEntry> forConversation(String id) =>
      List.unmodifiable(state.where((entry) => entry.conversationId == id));

  String exportConversation(String id) =>
      forConversation(id).map((entry) => jsonEncode(entry.toJson())).join('\n');

  Future<void> clearConversation(String id) async {
    state = List.unmodifiable(
      state.where((entry) => entry.conversationId != id),
    );
    _snapshot = jsonEncode(state.map((entry) => entry.toJson()).toList());
    await flush();
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    return _enqueueSave(_snapshot);
  }

  Future<void> _enqueueSave(String snapshot) {
    _pending = _pending
        .then((_) async {
          if (!await _prefs.setString(storageKey, snapshot)) {
            throw StateError('log persistence failed');
          }
        })
        .catchError((Object _) {
          debugPrint('Unable to persist runtime diagnostics');
        });
    return _pending;
  }
}
