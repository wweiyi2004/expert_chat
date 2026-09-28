import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/model_connection_tester.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/features/settings/model_setup_page.dart';
import 'package:expert_chat/features/shared/recovery_notice.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart' show InMemoryRepo, FakeLlmProvider;

class _Probe extends ModelConnectionTester {
  _Probe() : super(FakeLlmProvider(const []));
  final calls = <LlmConfig>[];
  Object? failure;
  bool waitForCancel = false;
  @override
  Future<Duration> check(
    LlmConfig config, {
    required CancelToken cancelToken,
  }) async {
    calls.add(config);
    if (waitForCancel) throw await cancelToken.whenCancel;
    if (failure != null) throw failure!;
    return const Duration(milliseconds: 50);
  }
}

class _Storage extends TestFlutterSecureStoragePlatform {
  _Storage() : super({});
  bool failNextWrite = false;
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('模拟安全存储失败');
    }
    await super.write(key: key, value: value, options: options);
  }
}

void main() {
  late ProviderContainer container;
  late SharedPreferences prefs;
  late AppDatabase db;
  late _Probe probe;
  late _Storage storage;
  late FakeLlmProvider llm;

  Future<void> pump(WidgetTester tester, {bool phone = false}) async {
    await tester.binding.setSurfaceSize(
      phone ? const Size(360, 740) : const Size(1000, 900),
    );
    SharedPreferences.setMockInitialValues({});
    storage = _Storage();
    FlutterSecureStoragePlatform.instance = storage;
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase(NativeDatabase.memory());
    probe = _Probe();
    llm = FakeLlmProvider(const [ChatChunk(contentDelta: '你好，连接正常。')]);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(prefs),
        conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
        modelConnectionTesterProvider.overrideWithValue(probe),
        llmProvider.overrideWithValue(llm),
      ],
    );
    await container.read(settingsControllerProvider.future);
    await container.read(chatControllerProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const ChatPage()),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
  }

  Future<void> open(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(const ValueKey('chat-connect-model')),
    );
    await tester.tap(find.byKey(const ValueKey('chat-connect-model')));
    await tester.pumpAndSettle();
  }

  Future<void> enterKey(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('setup-key')));
    await tester.enterText(
      find.byKey(const ValueKey('setup-key')),
      'opaque-test-key',
    );
  }

  Future<void> check(WidgetTester tester) async {
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'first setup verifies, saves securely, preserves draft and sends first reply',
    (tester) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('composer-text-field')),
        '我的第一个问题',
      );
      await open(tester);
      await enterKey(tester);
      await check(tester);
      expect(probe.calls, hasLength(1));
      expect(
        container.read(settingsControllerProvider).requireValue.apiKey,
        isEmpty,
      );
      expect(storage.data.values, isNot(contains('opaque-test-key')));
      await tester.ensureVisible(find.text('保存并开始对话'));
      await tester.tap(find.text('保存并开始对话'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelSetupPage), findsNothing);
      expect(find.text('我的第一个问题'), findsOneWidget);
      expect(
        container.read(settingsControllerProvider).requireValue.apiKey,
        'opaque-test-key',
      );
      expect(storage.data.values, contains('opaque-test-key'));
      expect(
        prefs.getKeys().map(prefs.get).join(),
        isNot(contains('opaque-test-key')),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      final observed = container.read(chatControllerProvider).requireValue;
      // The factory skill router can make a classification request; the
      // conversation itself must contain exactly one user turn and answer.
      expect(observed.current!.messagesLoaded, isTrue);
      expect(observed.current!.messages, hasLength(2));
      expect(observed.current!.messages.first.content, '我的第一个问题');
      expect(observed.current!.messages.last.content, '你好，连接正常。');
      expect(find.text('你好，连接正常。'), findsOneWidget);
      final reloaded = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      expect(
        (await reloaded.read(settingsControllerProvider.future)).apiKey,
        'opaque-test-key',
      );
      reloaded.dispose();
    },
  );

  testWidgets(
    'authentication failure keeps the draft and makes no persistent change',
    (tester) async {
      await pump(tester, phone: true);
      await open(tester);
      await enterKey(tester);
      final before = prefs.getString('providerProfiles');
      probe.failure = Exception('鉴权失败（401） opaque-test-key');
      await check(tester);
      expect(find.text('密钥未通过验证'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(RecoveryNotice),
          matching: find.textContaining('opaque-test-key'),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('setup-key')))
            .controller!
            .text,
        'opaque-test-key',
      );
      expect(prefs.getString('providerProfiles'), before);
      expect(storage.data.values, isNot(contains('opaque-test-key')));
      expect(find.text('保存并开始对话'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancel preserves fields and a changed model invalidates verification',
    (tester) async {
      await pump(tester);
      await open(tester);
      await enterKey(tester);
      probe.waitForCancel = true;
      await check(tester);
      await tester.ensureVisible(find.text('取消测试'));
      await tester.tap(find.text('取消测试'));
      await tester.pumpAndSettle();
      expect(find.text('测试已取消，填写内容已保留。'), findsOneWidget);
      expect(
        container.read(settingsControllerProvider).requireValue.apiKey,
        isEmpty,
      );
      probe.waitForCancel = false;
      await check(tester);
      expect(find.text('保存并开始对话'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('setup-model')));
      await tester.enterText(
        find.byKey(const ValueKey('setup-model')),
        'another-model',
      );
      await tester.pump();
      expect(find.text('保存并开始对话'), findsNothing);
      expect(find.text('测试连接'), findsOneWidget);
    },
  );

  testWidgets(
    'save failure does not publish configuration and can be retried without another probe',
    (tester) async {
      await pump(tester);
      await open(tester);
      await enterKey(tester);
      await check(tester);
      storage.failNextWrite = true;
      await tester.ensureVisible(find.text('保存并开始对话'));
      await tester.tap(find.text('保存并开始对话'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelSetupPage), findsOneWidget);
      expect(
        container.read(settingsControllerProvider).requireValue.apiKey,
        isEmpty,
      );
      await tester.ensureVisible(find.text('保存并开始对话'));
      await tester.tap(find.text('保存并开始对话'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelSetupPage), findsNothing);
      expect(probe.calls, hasLength(1));
      expect(
        container.read(settingsControllerProvider).requireValue.apiKey,
        'opaque-test-key',
      );
    },
  );

  testWidgets('changing the endpoint host clears the previous service key', (
    tester,
  ) async {
    await pump(tester);
    await open(tester);
    await enterKey(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('setup-url')));
    await tester.enterText(
      find.byKey(const ValueKey('setup-url')),
      'https://other.example/v1',
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('setup-key')))
          .controller!
          .text,
      isEmpty,
    );
    await check(tester);
    expect(probe.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
