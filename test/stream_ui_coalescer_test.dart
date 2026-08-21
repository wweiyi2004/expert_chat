import 'package:expert_chat/domain/chat/stream_ui_coalescer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('estimateStreamTokens', () {
    test('counts CJK characters as one token each', () {
      expect(estimateStreamTokens('你好世界'), 4);
    });

    test('counts about four Latin characters as one token', () {
      expect(estimateStreamTokens('abcd'), 1);
      expect(estimateStreamTokens('abcdefgh'), 2);
    });

    test('returns zero for empty text', () {
      expect(estimateStreamTokens(''), 0);
    });
  });

  group('StreamUiCoalescer', () {
    test('first paint stays snappy before a full token batch', () {
      final coalescer = StreamUiCoalescer();
      coalescer.add('短');
      expect(coalescer.shouldFlushNow, isFalse);
      expect(coalescer.delay, StreamUiCoalescer.firstPaintDelay);
      expect(coalescer.tokenBatch, StreamUiCoalescer.shortBatch);
    });

    test('flushes immediately after first paint once a short batch arrives', () {
      final coalescer = StreamUiCoalescer();
      coalescer.add('短');
      coalescer.markFlushed();

      coalescer.add(List.filled(StreamUiCoalescer.shortBatch, '字').join());
      expect(coalescer.shouldFlushNow, isTrue);
      expect(coalescer.delay, StreamUiCoalescer.shortFallback);
    });

    test('does not flush immediately for a small follow-up batch', () {
      final coalescer = StreamUiCoalescer();
      coalescer.markFlushed();
      coalescer.add('还行');
      expect(coalescer.shouldFlushNow, isFalse);
      expect(coalescer.delay, StreamUiCoalescer.shortFallback);
    });

    test('resets pending tokens after a flush and keeps flushed total', () {
      final coalescer = StreamUiCoalescer();
      coalescer.add(List.filled(80, '字').join());
      coalescer.markFlushed();
      expect(coalescer.pendingTokens, 0);
      expect(coalescer.flushedTokens, 80);
      expect(coalescer.shouldFlushNow, isFalse);
    });

    test('long replies wait for a larger token batch', () {
      final coalescer = StreamUiCoalescer();
      coalescer.add(
        List.filled(StreamUiCoalescer.longAfterTokens, '字').join(),
      );
      coalescer.markFlushed();
      expect(coalescer.tokenBatch, StreamUiCoalescer.longBatch);
      expect(coalescer.delay, StreamUiCoalescer.longFallback);

      coalescer.add(List.filled(StreamUiCoalescer.longBatch - 1, '字').join());
      expect(coalescer.shouldFlushNow, isFalse);
      coalescer.add('字');
      expect(coalescer.shouldFlushNow, isTrue);
    });

    test('historical cache hit rate raises the short-stream batch', () {
      final coalescer = StreamUiCoalescer(cacheHitRate: 0.8);
      coalescer.markFlushed();
      expect(
        coalescer.tokenBatch,
        StreamUiCoalescer.shortBatch + StreamUiCoalescer.cacheHitShortBoost,
      );
      coalescer.add(
        List.filled(
          StreamUiCoalescer.shortBatch + StreamUiCoalescer.cacheHitShortBoost,
          '字',
        ).join(),
      );
      expect(coalescer.shouldFlushNow, isTrue);
    });

    test('fast arrival (cache-hit style) raises the short-stream batch', () {
      var now = DateTime.utc(2026, 1, 1);
      final coalescer = StreamUiCoalescer(now: () => now);
      coalescer.markFlushed();
      coalescer.add(List.filled(20, '字').join());
      now = now.add(StreamUiCoalescer.rateWindow);
      coalescer.add(List.filled(20, '字').join());
      expect(coalescer.tokensPerSecond, closeTo(200, 0.1));
      expect(
        coalescer.tokenBatch,
        StreamUiCoalescer.shortBatch + StreamUiCoalescer.cacheHitShortBoost,
      );
    });
  });

  group('DualStreamUiCoalescer', () {
    test('long reasoning does not enlarge the content batch', () {
      var focus = StreamUiFocus.reasoning;
      final dual = DualStreamUiCoalescer(focusOf: () => focus);
      dual.addReasoning(
        List.filled(StreamUiCoalescer.longAfterTokens, '字').join(),
      );
      dual.markFlushed();
      expect(dual.reasoning.tokenBatch, StreamUiCoalescer.longBatch);
      focus = StreamUiFocus.content;
      expect(dual.content.tokenBatch, StreamUiCoalescer.shortBatch);
      expect(dual.content.hasFlushed, isFalse);

      dual.addContent('答');
      expect(dual.shouldFlushNow, isFalse);
      expect(dual.delay, StreamUiCoalescer.firstPaintDelay);
    });

    test('content starts its own short curve after a long think', () {
      var focus = StreamUiFocus.reasoning;
      final dual = DualStreamUiCoalescer(focusOf: () => focus);
      dual.addReasoning(
        List.filled(StreamUiCoalescer.longAfterTokens, '字').join(),
      );
      dual.markFlushed();
      focus = StreamUiFocus.content;
      dual.addContent('答');
      dual.markFlushed();
      expect(dual.content.flushedTokens, 1);
      expect(dual.content.tokenBatch, StreamUiCoalescer.shortBatch);
      expect(dual.delay, StreamUiCoalescer.shortFallback);

      dual.addContent(List.filled(StreamUiCoalescer.shortBatch, '字').join());
      expect(dual.shouldFlushNow, isTrue);
    });

    test('uses the shorter delay when both panes have pending tokens', () {
      var focus = StreamUiFocus.reasoning;
      final dual = DualStreamUiCoalescer(focusOf: () => focus);
      dual.addReasoning(
        List.filled(StreamUiCoalescer.longAfterTokens, '字').join(),
      );
      dual.markFlushed();
      dual.addReasoning('还在想');
      dual.addContent('开始答');
      expect(dual.delay, StreamUiCoalescer.longFallback);
      focus = StreamUiFocus.content;
      expect(dual.delay, StreamUiCoalescer.firstPaintDelay);
    });

    test('content focus ignores a long reasoning backlog', () {
      final dual = DualStreamUiCoalescer(
        focusOf: () => StreamUiFocus.content,
      );
      dual.addReasoning(
        List.filled(StreamUiCoalescer.longAfterTokens, '字').join(),
      );
      expect(dual.shouldFlushNow, isFalse);
      dual.addContent('答');
      dual.markFlushed();
      dual.addContent(List.filled(StreamUiCoalescer.shortBatch, '字').join());
      expect(dual.shouldFlushNow, isTrue);
      expect(dual.reasoning.pendingTokens, StreamUiCoalescer.longAfterTokens);
    });

    test('away focus never flushes immediately', () {
      final dual = DualStreamUiCoalescer(focusOf: () => StreamUiFocus.away);
      dual.addContent(List.filled(200, '字').join());
      expect(dual.shouldFlushNow, isFalse);
      expect(dual.delay, DualStreamUiCoalescer.awayFallback);
    });
  });

  group('streamUiFocusFor', () {
    test('follows the answer tail while stuck to the bottom', () {
      expect(
        streamUiFocusFor(
          followingTail: true,
          hasContent: true,
          thinkingExpanded: false,
        ),
        StreamUiFocus.content,
      );
    });

    test('follows thinking while the answer has not started', () {
      expect(
        streamUiFocusFor(
          followingTail: true,
          hasContent: false,
          thinkingExpanded: true,
        ),
        StreamUiFocus.reasoning,
      );
    });

    test('watches thinking when expanded after scrolling away', () {
      expect(
        streamUiFocusFor(
          followingTail: false,
          hasContent: true,
          thinkingExpanded: true,
        ),
        StreamUiFocus.reasoning,
      );
    });

    test('freezes the prefix when the user is reading history', () {
      expect(
        streamUiFocusFor(
          followingTail: false,
          hasContent: true,
          thinkingExpanded: false,
        ),
        StreamUiFocus.away,
      );
    });
  });
}
