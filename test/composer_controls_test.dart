import 'package:expert_chat/data/composer_modes.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/chat/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'compact composer switches voice/send, keeps controls above, and opens bounded effort sheet',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final input = TextEditingController();
      addTearDown(input.dispose);
      var deepThink = false;
      var listening = false;
      var streaming = false;
      var effort = ReasoningEffort.high;
      var sent = 0;
      var stopped = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return ChatComposer(
                    controller: input,
                    isStreaming: streaming,
                    deepThink: deepThink,
                    supportsReasoningEffort: true,
                    reasoningEffort: effort,
                    searchMode: SearchMode.auto,
                    imageGenMode: ImageGenMode.off,
                    attachments: const [],
                    picking: false,
                    storyLike: false,
                    directorMode: false,
                    canAttachImages: true,
                    imageGenerationConfigured: false,
                    imageMode: false,
                    longTaskMode: false,
                    longTaskAvailable: false,
                    speechBusy: false,
                    speechListening: listening,
                    speechUsesCloudAsr: false,
                    onToggleDeepThink: () =>
                        update(() => deepThink = !deepThink),
                    onReasoningEffortChanged: (value) =>
                        update(() => effort = value),
                    onSetImageGenMode: (_) {},
                    onToggleImageMode: () {},
                    onToggleLongTask: () {},
                    onPickDocuments: () {},
                    onPickImages: () {},
                    onPickLibrary: () {},
                    onPaste: () async {},
                    onRemoveAttachment: (_) {},
                    onToggleSpeech: () => update(() => listening = !listening),
                    onSend: () => sent++,
                    onStop: () => stopped++,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('语音输入'), findsOneWidget);
      expect(find.byTooltip('发送'), findsNothing);
      final button = find.byKey(
        const ValueKey('composer-reasoning-effort-button'),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reasoning-effort-slider')),
        findsNothing,
      );
      input.text = '你好';
      await tester.pumpAndSettle();
      expect(find.byTooltip('语音输入'), findsNothing);
      expect(find.byTooltip('发送'), findsOneWidget);
      await tester.tap(find.byTooltip('发送'));
      expect(sent, 1);
      await tester.tap(find.text('深度思考'));
      await tester.pumpAndSettle();
      for (final label in ['深度思考', '思考档位']) {
        expect(find.text(label).hitTestable(), findsOneWidget);
        expect(
          tester.getBottomRight(find.text(label)).dy,
          lessThanOrEqualTo(
            tester
                .getTopLeft(find.byKey(const ValueKey('composer-input-box')))
                .dy,
          ),
        );
      }
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(sheet.left, greaterThanOrEqualTo(0));
      expect(sheet.right, lessThanOrEqualTo(320));
      expect(sheet.bottom, lessThanOrEqualTo(640));
      final slider = find.byKey(const ValueKey('reasoning-effort-slider'));
      final rect = tester.getRect(slider);
      await tester.tapAt(Offset(rect.right - 20, rect.center.dy));
      await tester.pumpAndSettle();
      expect(effort, ReasoningEffort.max);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      update(() => listening = true);
      await tester.pumpAndSettle();
      expect(find.byTooltip('发送'), findsOneWidget);
      input.clear();
      await tester.pumpAndSettle();
      expect(find.byTooltip('发送'), findsNothing);
      expect(find.byTooltip('停止语音输入'), findsOneWidget);
      update(() => streaming = true);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('停止'));
      expect(stopped, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
