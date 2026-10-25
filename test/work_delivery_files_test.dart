import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/features/chat/widgets/work_delivery_files.dart';
import 'package:expert_chat/state/work_changes.dart';

class _Files extends WorkChanges {
  _Files(this.files);
  final List<WorkFileChange> files;
  @override
  List<WorkFileChange> build() => files;
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final remote in [false, true]) {
      testWidgets(
        'delivery actions stay usable at 360 width on $platform remote=$remote',
        (tester) async {
          tester.view.physicalSize = const Size(360, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final file = WorkFileChange(
            id: 'f',
            conversationId: 'c',
            assistantId: 'a',
            target: remote
                ? '{"kind":"ssh","profileId":"lab"}'
                : '{"kind":"local","root":"fixture"}',
            scope: '.',
            path:
                'a/very/long/directory/containing/a/final-delivery-document.md',
            before: 'old',
            after: 'new',
            beforeHash: 'old',
            afterHash: 'new',
            deliveryHash: 'new',
            updatedAt: DateTime(2026),
          );
          WorkFileChange? opened;
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                workChangesProvider.overrideWith(() => _Files([file])),
              ],
              child: MaterialApp(
                theme: AppTheme.light(),
                home: Scaffold(
                  body: WorkDeliveryFiles(
                    conversationId: 'c',
                    assistantId: 'a',
                    onOpen: (value) => opened = value,
                  ),
                ),
              ),
            ),
          );
          expect(find.text('在工作台预览'), findsOneWidget);
          await tester.tap(find.text('在工作台预览'));
          expect(opened, same(file));
          if (remote || platform == TargetPlatform.android) {
            expect(find.text('打开位置'), findsNothing);
            await tester.tap(find.text('复制位置'));
            await tester.pump();
            expect(copied, contains(file.path));
          } else {
            expect(find.text('打开位置'), findsOneWidget);
            expect(find.text('复制位置'), findsNothing);
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
}
