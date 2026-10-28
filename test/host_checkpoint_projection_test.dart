import 'package:test/test.dart';
import 'package:expert_chat/data/chat_state.dart';
import 'package:expert_chat/domain/host/wire_models.dart';

void main() {
  for (final status in [
    SessionExecutionStatus.running,
    SessionExecutionStatus.waiting,
  ]) {
    test(
      'live $status projection preserves execution; disk recovery still interrupts',
      () {
        final raw = SessionExecutionCheckpoint(
          conversationId: 'c',
          status: status,
          updatedAt: DateTime.now(),
          phase: '等待计划审核',
          taskState: {'rootId': 'root', 'resumeRequired': false},
        ).toJson();
        final projected = decodeChatState({
          'sessionCheckpoints': {'c': raw},
        }).sessionCheckpoints['c']!;
        expect(projected.status, status);
        expect(projected.phase, '等待计划审核');
        expect(projected.resumeRequired, isFalse);
        final recovered = SessionExecutionCheckpoint.fromJson(raw);
        expect(recovered.status, SessionExecutionStatus.interrupted);
        expect(recovered.resumeRequired, isTrue);
      },
    );
  }
}
