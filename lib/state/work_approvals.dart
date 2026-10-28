import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

class PendingWorkApproval {
  PendingWorkApproval({
    required this.id,
    required this.conversationId,
    this.sourceAgentId,
    this.toolCallId,
    required this.tool,
    required this.arguments,
    required this.target,
    required this.reason,
  });
  final String? sourceAgentId, toolCallId;
  final String id, conversationId, tool, arguments, target, reason;
  final Completer<bool> decision = Completer<bool>();
  String? denialReason;
}

final workApprovalsProvider =
    NotifierProvider<WorkApprovals, List<PendingWorkApproval>>(
      WorkApprovals.new,
    );

class WorkApprovals extends Notifier<List<PendingWorkApproval>> {
  final Map<String, PendingWorkApproval> _waiting = {};
  final Set<String> _sessionAllowed = {};
  final Map<String, String> _denials = {};
  void revokeSession(String conversation) {
    bool matches(String key) => (jsonDecode(key) as List).first == conversation;
    _sessionAllowed.removeWhere(matches);
    _denials.removeWhere((key, _) => matches(key));
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  static String operationKey(
    String conversation,
    String tool,
    String arguments,
    String target,
  ) {
    Object? args;
    try {
      args = _canonical(jsonDecode(arguments));
    } catch (_) {
      args = arguments;
    }
    return jsonEncode([conversation, target, tool, args]);
  }

  bool isAllowed(
    String conversation,
    String tool,
    String arguments,
    String target,
  ) => _sessionAllowed.contains(
    operationKey(conversation, tool, arguments, target),
  );
  String? takeDenial(
    String conversation,
    String tool,
    String arguments,
    String target,
  ) => _denials.remove(operationKey(conversation, tool, arguments, target));
  void decideScoped(
    String conversation,
    String id,
    String decision, {
    String? reason,
  }) {
    final request = state
        .where((r) => r.id == id && r.conversationId == conversation)
        .firstOrNull;
    if (request == null || request.decision.isCompleted) {
      throw StateError('批准请求已失效');
    }
    if (!{'once', 'session', 'reject', 'reject_reason'}.contains(decision)) {
      throw ArgumentError('无效批准决定');
    }
    if (decision == 'reject_reason' &&
        (reason == null || reason.trim().isEmpty)) {
      throw ArgumentError('请填写拒绝原因');
    }
    final key = operationKey(
      conversation,
      request.tool,
      request.arguments,
      request.target,
    );
    if (decision == 'session') _sessionAllowed.add(key);
    if (decision == 'reject_reason') _denials[key] = reason!.trim();
    request.decision.complete(decision == 'once' || decision == 'session');
  }

  @override
  List<PendingWorkApproval> build() {
    ref.onDispose(() {
      for (final request in _waiting.values) {
        if (!request.decision.isCompleted) request.decision.complete(false);
      }
    });
    return [];
  }

  Future<bool> ask(PendingWorkApproval request, CancelToken token) async {
    if (token.isCancelled) return false;
    _waiting[request.id] = request;
    state = [...state, request];
    try {
      return await Future.any([
        request.decision.future,
        token.whenCancel.then((_) => false),
      ]);
    } finally {
      _waiting.remove(request.id);
      if (ref.mounted) state = state.where((r) => r.id != request.id).toList();
    }
  }

  void decide(String id, bool approved) {
    final request = state.where((r) => r.id == id).firstOrNull;
    if (request != null && !request.decision.isCompleted) {
      request.decision.complete(approved);
    }
  }
}
