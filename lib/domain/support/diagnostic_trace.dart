import 'dart:convert';

enum DiagnosticOperation { generation, toolBatch }

enum DiagnosticPhase { started, finished, cancelled, failed, budgetExhausted }

/// Opt-in, bounded, process-local metadata. There is deliberately no API for
/// arbitrary text, exception objects, URLs, model inputs or credentials.
class DiagnosticTrace {
  static final instance = DiagnosticTrace();
  bool _enabled = false;
  int _sequence = 0;
  final List<Map<String, Object>> _events = [];
  bool get enabled => _enabled;

  void setEnabled(bool value) {
    _enabled = value;
    if (!value) _events.clear();
  }

  DiagnosticTicket? start(DiagnosticOperation operation) {
    if (!_enabled) return null;
    final ticket = DiagnosticTicket._(++_sequence, operation);
    record(ticket, DiagnosticPhase.started);
    return ticket;
  }

  void record(DiagnosticTicket? ticket, DiagnosticPhase phase) {
    if (!_enabled || ticket == null) return;
    _events.add({
      'id': ticket.id,
      'operation': ticket.operation.name,
      'phase': phase.name,
      'elapsedMs': ticket.elapsed.elapsedMilliseconds,
      'time': DateTime.now().toUtc().toIso8601String(),
    });
    if (_events.length > 128) _events.removeAt(0);
  }

  String exportText() => _enabled
      ? '\n本次运行的诊断步骤（用户选择包含）：\n${const JsonEncoder.withIndent('  ').convert(_events)}\n'
      : '';
}

class DiagnosticTicket {
  DiagnosticTicket._(this.id, this.operation);
  final int id;
  final DiagnosticOperation operation;
  final Stopwatch elapsed = Stopwatch()..start();
}
