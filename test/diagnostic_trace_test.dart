import 'dart:convert';
import 'package:expert_chat/domain/chat/generation_execution.dart';
import 'package:expert_chat/domain/support/diagnostic_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => DiagnosticTrace.instance.setEnabled(false));
  test('generation trace is opt-in, bounded and cleared on disable', () async {
    final trace = DiagnosticTrace.instance;
    final execution = GenerationExecution();
    execution.tryStart();
    execution.finish();
    expect(trace.exportText(), isEmpty);
    trace.setEnabled(true);
    execution.tryStart();
    await execution.runTools(() async => 1);
    execution.cancel();
    execution.finish();
    var text = trace.exportText();
    final events = jsonDecode(text.substring(text.indexOf('['))) as List;
    expect(events.last['phase'], 'cancelled');
    expect(events.first['id'], events.last['id']);
    for (var i = 0; i < 100; i++) {
      execution.tryStart();
      execution.finish();
    }
    text = trace.exportText();
    expect(jsonDecode(text.substring(text.indexOf('['))), hasLength(128));
    trace.setEnabled(false);
    trace.setEnabled(true);
    text = trace.exportText();
    expect(jsonDecode(text.substring(text.indexOf('['))), isEmpty);
    execution.dispose();
  });
}
