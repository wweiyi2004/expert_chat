import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/domain/notify/generation_notify.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _Lifecycle extends WidgetsBindingObserver {
  bool background = false;
  bool sawBackground = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    background =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    sawBackground |= background;
    GenerationNotify.setAppBackground(background);
  }
}

/// Host drives Home/lock/unlock after BACKGROUND_STREAM_READY. Uses a local SSE
/// endpoint, no real credentials, conversations, or provider charges.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android continues receiving SSE while backgrounded and locked',
    (tester) async {
      final lifecycle = _Lifecycle();
      WidgetsBinding.instance.addObserver(lifecycle);
      addTearDown(() => WidgetsBinding.instance.removeObserver(lifecycle));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Timer? sender;
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.bufferOutput = false;
        request.response.write(
          'data: {"choices":[{"delta":{"content":"0,"}}]}\n\n',
        );
        await request.response.flush();
        var index = 0;
        sender = Timer.periodic(const Duration(seconds: 1), (_) {
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '${++index},'},
                },
              ],
            })}\n\n',
          );
          unawaited(request.response.flush());
        });
      });
      addTearDown(() => sender?.cancel());
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Background stream verification')),
        ),
      );
      await tester.runAsync(() async {
        await GenerationNotify.onGenerationStart();
        var received = 0;
        var receivedInBackground = 0;
        final firstChunk = Completer<void>();
        final cancelToken = CancelToken();
        Object? streamError;
        final subscription = OpenAiCompatibleProvider()
            .streamChat(
              config: LlmConfig(
                baseUrl: 'http://127.0.0.1:${server.port}',
                apiKey: 'local-test',
                model: 'test',
              ),
              messages: const [
                LlmRequestMessage(
                  role: MessageRole.user,
                  content: 'local test',
                ),
              ],
              cancelToken: cancelToken,
            )
            .listen(
              (chunk) {
                if (chunk.contentDelta == null) return;
                received++;
                if (!firstChunk.isCompleted) firstChunk.complete();
                if (lifecycle.background) receivedInBackground++;
              },
              onError: (Object error) {
                streamError = error;
              },
            );
        try {
          // Verify the fixture really streams before the host presses Home.
          await firstChunk.future.timeout(const Duration(seconds: 10));
          debugPrint('BACKGROUND_STREAM_READY');
          final deadline = DateTime.now().add(const Duration(seconds: 100));
          while (DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            if (lifecycle.sawBackground &&
                !lifecycle.background &&
                receivedInBackground >= 20) {
              break;
            }
          }
          debugPrint(
            'BACKGROUND_STREAM_COUNTS received=$received background=$receivedInBackground',
          );
          expect(lifecycle.sawBackground, isTrue);
          expect(lifecycle.background, isFalse);
          expect(streamError, isNull);
          expect(receivedInBackground, greaterThanOrEqualTo(20));
          debugPrint(
            'BACKGROUND_STREAM_RESULT received=$received background=$receivedInBackground',
          );
        } finally {
          sender?.cancel();
          cancelToken.cancel('background test complete');
          await subscription.cancel();
          await GenerationNotify.onGenerationEnd(
            success: false,
            conversationTitle: '',
            cancelled: true,
          );
        }
      });
      await tester.pump();
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
