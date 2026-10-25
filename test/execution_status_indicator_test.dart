import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/features/chat/widgets/execution_status_indicator.dart';

void main() {
  testWidgets(
    'reduced motion stops each looping ticker and restarting motion resumes it',
    (tester) async {
      var reduce = false;
      var status = ExecutionVisualStatus.running;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQueryData(disableAnimations: reduce),
                child: ExecutionStatusIndicator(status: status),
              );
            },
          ),
        ),
      );
      for (final value in [
        ExecutionVisualStatus.running,
        ExecutionVisualStatus.waiting,
        ExecutionVisualStatus.queued,
      ]) {
        update(() {
          status = value;
          reduce = false;
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          SchedulerBinding.instance.transientCallbackCount,
          greaterThan(0),
        );
        update(() => reduce = true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(SchedulerBinding.instance.transientCallbackCount, 0);
      }
      update(() => reduce = false);
      await tester.pump();
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('completion appears as a check and failure as a cross', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            ExecutionStatusIndicator(status: ExecutionVisualStatus.completed),
            ExecutionStatusIndicator(status: ExecutionVisualStatus.failed),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
