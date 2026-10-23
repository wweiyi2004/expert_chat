import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PendingWorkApproval {
  PendingWorkApproval({
    required this.id,
    required this.conversationId,
    this.sourceAgentId,
    required this.tool,
    required this.arguments,
    required this.target,
    required this.reason,
  });
  final String? sourceAgentId;
  final String id, conversationId, tool, arguments, target, reason;
  final Completer<bool> decision = Completer<bool>();
}

final workApprovalsProvider =
    NotifierProvider<WorkApprovals, List<PendingWorkApproval>>(
      WorkApprovals.new,
    );

class WorkApprovals extends Notifier<List<PendingWorkApproval>> {
  final Map<String, PendingWorkApproval> _waiting = {};
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
