import 'dart:async';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/runtime/embedded_runtime.dart';
import 'package:expert_chat/features/remote/device_agent_page.dart';
import 'package:expert_chat/features/chat/widgets/chat_workspace_options.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _LiveModel implements LlmProvider {
  CancelToken? token;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    token = cancelToken;
    yield const ChatChunk(contentDelta: '正在处理');
    await cancelToken!.whenCancel;
    yield const ChatChunk(finishReason: 'stop');
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'mobile runtime preserves background work and closes it once',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      final model = _LiveModel();
      var storageClosed = 0;
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          desktopWorkspaceHostProvider.overrideWithValue(
            stub.createDesktopWorkspaceHost(),
          ),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          llmProvider.overrideWithValue(model),
        ],
      );
      final runtime = EmbeddedRuntime(
        container,
        closeStorage: () async {
          storageClosed++;
          await db.close();
        },
      );
      addTearDown(runtime.close);
      await container.read(chatControllerProvider.future);
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final pending = controller.sendToSession(id, 'mobile runtime task');
      for (var i = 0; i < 200 && model.token == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(model.token, isNotNull);
      runtime.reportBackground(true);
      expect(model.token!.isCancelled, isFalse);
      expect(runtime.closed, isFalse);
      runtime.reportBackground(false);
      await Future.wait([runtime.close(), runtime.close()]);
      await pending;
      expect(model.token!.isCancelled, isTrue);
      expect(storageClosed, 1);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  testWidgets(
    'device control refreshes consent state and needs an explicit start',
    (tester) async {
      var enabled = false, armed = false;
      final calls = <String>[];
      const channel = MethodChannel('expert_chat/device_agent');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        switch (call.method) {
          case 'status':
            return {'enabled': enabled, 'armed': armed, 'sdk': 36};
          case 'arm':
            armed = true;
            return {'revision': 1, 'nodes': []};
          case 'stop':
            armed = false;
            return {'revision': 2, 'nodes': []};
          default:
            return null;
        }
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: DeviceAgentPage()));
      await tester.pumpAndSettle();
      expect(find.text('系统服务未开启'), findsOneWidget);
      expect(calls, ['status']);
      enabled = true;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('系统服务已开启'), findsOneWidget);
      expect(calls.contains('arm'), isFalse);
      await tester.tap(find.text('开启本次控制'));
      await tester.pumpAndSettle();
      expect(find.text('本次控制已开启'), findsOneWidget);
      await tester.tap(find.text('立即停止'));
      await tester.pumpAndSettle();
      expect(find.text('本次控制未开启'), findsOneWidget);
      expect(armed, isFalse);
    },
  );

  testWidgets(
    'Android execution picker offers device instead of a desktop directory',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          desktopWorkspaceHostProvider.overrideWithValue(
            stub.createDesktopWorkspaceHost(),
          ),
          settingsControllerProvider.overrideWith(FakeSettings.new),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: ChatWorkspaceBar(conversationId: 'phone', busy: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本机 · Android'), findsOneWidget);
      await tester.tap(find.text('本机 · Android'));
      await tester.pumpAndSettle();
      expect(find.text('当前设备'), findsOneWidget);
      expect(find.text('Android 本机控制'), findsOneWidget);
      expect(find.text('管理工作区和权限'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await db.close();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
