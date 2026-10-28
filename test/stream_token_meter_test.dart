import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/stream_token_meter.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';

void main() {
  test(
    'cancellation reaches a silent source and waits for its cleanup',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final source = StreamController<ChatChunk>(
        onCancel: () {
          entered.complete();
          return release.future;
        },
      );
      final meter = StreamTokenMeter(10);
      final received = <ChatChunk>[];
      final subscription = meter.watch(source.stream).listen(received.add);
      source.add(const ChatChunk(contentDelta: 'first'));
      await Future<void>.delayed(Duration.zero);
      var finished = false;
      final cancelled = subscription.cancel().then((_) => finished = true);
      await entered.future.timeout(const Duration(seconds: 1));
      expect(finished, isFalse);
      expect(meter.active, isFalse);
      source.add(const ChatChunk(contentDelta: 'late'));
      release.complete();
      await cancelled;
      await source.close();
      expect(received, hasLength(1));
    },
  );
}
