import 'package:dio/dio.dart';
import 'package:expert_chat/data/jev_config.dart';
import 'package:expert_chat/domain/llm/jev_client.dart';
import 'package:expert_chat/features/settings/widgets/jev_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends JevClient {
  String? key;
  Object? sentState;
  CancelToken? cancel;
  bool hold = false;
  bool fail = false;

  @override
  Future<JevChoice> choose({
    required String apiKey,
    required String model,
    required Object state,
    required String instructions,
    required Map<String, String> criteria,
    CancelToken? cancelToken,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    key = apiKey;
    sentState = state;
    cancel = cancelToken;
    if (hold) {
      await cancelToken!.whenCancel;
      throw const JevException(JevFailure.cancelled);
    }
    if (fail) throw const JevException(JevFailure.unauthorized);
    return const JevChoice(choice: 'translate', confidence: 0.9);
  }
}

void main() {
  late _Client client;
  setUp(() {
    client = _Client();
    addTearDown(client.close);
  });

  Future<void> mount(
    WidgetTester tester, {
    String initialKey = 'test-key',
  }) async {
    var config = const JevConfig();
    var key = initialKey;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: JevSettingsCard(
                  config: config,
                  apiKey: key,
                  client: client,
                  onConfigChanged: (next) async => update(() => config = next),
                  onApiKeySaved: (next) async => update(() => key = next),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('narrow layout saves key and tests only the fixed sample', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, initialKey: '');
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '测试 Jev 连接'),
          )
          .onPressed,
      isNull,
    );
    final keyField = find.descendant(
      of: find.byKey(const ValueKey('jev_api_key')),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(keyField).obscureText, isTrue);
    await tester.enterText(keyField, 'new-key');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final testButton = find.text('测试 Jev 连接');
    await tester.ensureVisible(testButton);
    await tester.tap(testButton);
    await tester.pumpAndSettle();
    expect(client.key, 'new-key');
    expect(client.sentState, '请把这句话翻译成英语：你好。');
    expect(find.textContaining('连接成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection failure gives a safe actionable message', (
    tester,
  ) async {
    client.fail = true;
    await mount(tester);
    await tester.ensureVisible(find.text('测试 Jev 连接'));
    await tester.tap(find.text('测试 Jev 连接'));
    await tester.pumpAndSettle();
    expect(find.text('Jev 密钥无效或尚未获得访问权限。'), findsOneWidget);
    expect(find.textContaining('Bearer'), findsNothing);
  });

  testWidgets('leaving settings cancels the connection test', (tester) async {
    client.hold = true;
    await mount(tester);
    await tester.ensureVisible(find.text('测试 Jev 连接'));
    await tester.tap(find.text('测试 Jev 连接'));
    await tester.pump();
    expect(client.cancel!.isCancelled, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(client.cancel!.isCancelled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
