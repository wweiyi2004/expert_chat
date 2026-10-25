import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'chat_controller.dart';
import 'work_agents.dart';
import 'work_processes.dart';
import 'work_approvals.dart';
import 'work_questions.dart';

/// Shared active-task semantics for navigation, including detached work.
final conversationActiveIdsProvider = Provider<Set<String>>((ref) {
  final chat = ref.watch(chatControllerProvider).value;
  final agents = ref.watch(workAgentsProvider);
  final processes = ref.watch(workProcessesProvider);
  void refresh() => ref.invalidateSelf();
  agents.addListener(refresh);
  processes.addListener(refresh);
  ref.onDispose(() {
    agents.removeListener(refresh);
    processes.removeListener(refresh);
  });
  return {
    ...?chat?.runningConversationIds,
    for (final checkpoint
        in chat?.sessionCheckpoints.values ?? <SessionExecutionCheckpoint>[])
      if (checkpoint.status == SessionExecutionStatus.waiting)
        checkpoint.conversationId,
    for (final a in agents.records)
      if (!a.external && !a.terminal) a.conversationId,
    for (final p in processes.records)
      if (!p.service && p.active) p.conversationId,
    ...ref.watch(workApprovalsProvider).map((a) => a.conversationId),
    ...ref.watch(workQuestionsProvider).map((q) => q.conversationId),
  };
});
