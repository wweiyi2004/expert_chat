import 'package:expert_chat/domain/chat/stream_answer_buffer.dart';
import 'package:expert_chat/domain/chat/stream_answer_presenter.dart';
import 'package:expert_chat/domain/chat/stream_ui_coalescer.dart';
import 'package:flutter_test/flutter_test.dart';

class _ThinkingClock implements Stopwatch {
  @override
  bool isRunning = false;
  @override
  int elapsedMilliseconds = 0;
  @override
  void start() => isRunning = true;
  @override
  void stop() => isRunning = false;
  void elapse(int millis) {
    if (isRunning) elapsedMilliseconds += millis;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('thinking time accumulates across rounds and excludes tool waiting', () {
    final clock = _ThinkingClock();
    final buffer = StreamAnswerBuffer(thinkingClock: clock);
    buffer.appendReasoningNote('任务提示');
    buffer.addReasoning('');
    expect(buffer.isThinking, isFalse);
    buffer.addReasoning('第一轮');
    clock.elapse(120);
    expect(buffer.thinkingMillis, 0, reason: '时长在思考结束时记录');
    buffer.addContent('先查资料');
    expect(buffer.thinkingMillis, 120);
    clock.elapse(900);
    buffer.replaceContent('');
    buffer.addReasoning('第二轮');
    clock.elapse(80);
    buffer.stopThinking();
    buffer.addContent('最后答复');
    expect(buffer.thinkingMillis, 200);
    expect(buffer.reasoning, '任务提示第一轮第二轮');
    expect(buffer.content, '最后答复');
  });

  testWidgets('first paint and focus changes keep independent pane snapshots', (
    tester,
  ) async {
    var focus = StreamUiFocus.reasoning;
    final snapshots = <StreamAnswerSnapshot>[];
    final presenter = StreamAnswerPresenter(
      buffer: StreamAnswerBuffer(),
      focusOf: () => focus,
      onPublish: snapshots.add,
      onCheckpoint: () {},
    );
    addTearDown(presenter.dispose);
    presenter.addReasoning('思考');
    presenter.addContent('正文');
    presenter.scheduleFlush();
    await tester.pump(const Duration(milliseconds: 29));
    expect(snapshots, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(snapshots.single.reasoning, '思考');
    expect(snapshots.single.content, '');
    focus = StreamUiFocus.content;
    presenter.nudge();
    expect(snapshots.last.content, '正文');
    presenter.addReasoning('隐藏增量');
    presenter.scheduleFlush();
    await tester.pump(const Duration(seconds: 1));
    expect(snapshots, hasLength(2));
    expect(snapshots.last.reasoning, '思考');
    presenter.flush(publishAll: true);
    expect(snapshots.last.reasoning, '思考隐藏增量');
  });

  testWidgets('first answer replaces a long thinking timer with a short wait', (
    tester,
  ) async {
    var focus = StreamUiFocus.reasoning;
    final snapshots = <StreamAnswerSnapshot>[];
    final presenter = StreamAnswerPresenter(
      buffer: StreamAnswerBuffer(),
      focusOf: () => focus,
      onPublish: snapshots.add,
      onCheckpoint: () {},
    );
    addTearDown(presenter.dispose);
    presenter.addReasoning(List.filled(300, '想').join());
    presenter.nudge();
    presenter.addReasoning('继续想');
    presenter.scheduleFlush();
    focus = StreamUiFocus.content;
    presenter.addContent('答案');
    presenter.scheduleFlush();
    await tester.pump(const Duration(milliseconds: 30));
    expect(snapshots, hasLength(2));
    expect(snapshots.last.content, '答案');
    expect(snapshots.last.reasoning, isNot(endsWith('继续想')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(snapshots, hasLength(2), reason: '旧的思考刷新定时器已取消');
  });

  testWidgets(
    'away mode batches both panes and stop flushes all before disposal',
    (tester) async {
      final snapshots = <StreamAnswerSnapshot>[];
      final presenter = StreamAnswerPresenter(
        buffer: StreamAnswerBuffer(),
        focusOf: () => StreamUiFocus.away,
        onPublish: snapshots.add,
        onCheckpoint: () {},
      );
      presenter.addReasoning('思考');
      presenter.addContent('正文');
      presenter.scheduleFlush();
      await tester.pump(const Duration(milliseconds: 2999));
      expect(snapshots, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(snapshots.single.content, '正文');
      expect(snapshots.single.reasoning, '思考');
      presenter.addContent('尚未显示');
      presenter.scheduleFlush();
      presenter.flush(publishAll: true);
      expect(snapshots.last.content, '正文尚未显示');
      presenter.addContent('待刷新');
      presenter.scheduleFlush();
      presenter.dispose();
      presenter.addContent('迟到');
      presenter.nudge();
      await tester.pump(const Duration(seconds: 4));
      expect(snapshots, hasLength(2));
    },
  );

  test(
    'checkpoints use elapsed time or growth and follow snapshot publication',
    () {
      var now = DateTime(2026);
      final writes = <StreamAnswerSnapshot>[];
      StreamAnswerSnapshot? latest;
      final presenter = StreamAnswerPresenter(
        buffer: StreamAnswerBuffer(),
        focusOf: () => StreamUiFocus.content,
        now: () => now,
        onPublish: (value) => latest = value,
        onCheckpoint: () => writes.add(latest!),
      );
      addTearDown(presenter.dispose);
      now = now.add(const Duration(seconds: 3));
      presenter.flush(publishAll: true);
      expect(writes, isEmpty);
      presenter.addContent('a');
      presenter.flush(publishAll: true);
      expect(writes.single.content, 'a');
      presenter.addContent(List.filled(8191, 'b').join());
      presenter.flush(publishAll: true);
      expect(writes, hasLength(1));
      presenter.addReasoning('c');
      presenter.flush(publishAll: true);
      expect(writes, hasLength(2));
      expect(writes.last.reasoning, 'c');
      presenter.flush(publishAll: true);
      expect(writes, hasLength(2));
      now = now.add(const Duration(seconds: 3));
      presenter.flush(publishAll: true);
      expect(writes, hasLength(3));
    },
  );

  test(
    'tool preamble clearing and reasoning recovery replace visible text',
    () {
      final buffer = StreamAnswerBuffer();
      final snapshots = <StreamAnswerSnapshot>[];
      final presenter = StreamAnswerPresenter(
        buffer: buffer,
        focusOf: () => StreamUiFocus.reasoning,
        onPublish: snapshots.add,
        onCheckpoint: () {},
      );
      addTearDown(presenter.dispose);
      presenter.addContent('先搜索');
      presenter.addReasoning('此前思考');
      presenter.flush(publishAll: true);
      buffer.replaceContent('');
      presenter.flush(publishAll: true);
      expect(snapshots.last.content, '');
      buffer.replaceReasoning('此前思考及后续分析');
      buffer.replaceContent('恢复的完整答案');
      presenter.flush(publishAll: true);
      expect(snapshots.last.content, '恢复的完整答案');
      expect(snapshots.last.reasoning, '此前思考及后续分析');
      expect(snapshots.first.content, '先搜索', reason: '已经发布的快照不被修改');
      expect(StreamAnswerBuffer().totalLength, 0);
    },
  );
}
