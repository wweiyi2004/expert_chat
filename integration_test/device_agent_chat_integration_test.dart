import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart'
    as unsupported;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/remote/device_agent.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_changes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test/widget_test.dart' show FakeSettings, InMemoryRepo;

class _NativeFixtureSettings extends FakeSettings {
  @override
  Future<SettingsState> build() async {
    final original = await super.build();
    final profile = ProviderProfile(
      id: 'native-controller-fixture',
      name: 'Offline native fixture',
      baseUrl: 'https://fixture.invalid',
      chatModel: 'gpt-4o',
      reasonerModel: 'gpt-4o',
      models: const ['gpt-4o'],
    );
    return original.copyWith(
      profiles: [profile],
      activeProfileId: profile.id,
      selectedModel: 'gpt-4o',
      apiKey: 'fixture-only-no-network',
      searchApiKey: '',
      gateway: const GatewayConfig(enabled: false),
    );
  }
}

class _TransientChanges extends WorkChanges {
  @override
  List<WorkFileChange> build() {
    ready = Future.value();
    return [];
  }
}

class _NativePlan implements LlmProvider {
  int calls = 0;
  bool sawImage = false;
  Uint8List? png;
  Map<String, dynamic>? screenshot;
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
    expect(config.baseUrl, 'https://fixture.invalid');
    calls++;
    if (calls == 1) {
      expect(tools!.any((t) => t.name == 'device_observe'), isTrue);
      yield const ChatChunk(
        toolCalls: [
          ToolCall(
            index: 0,
            id: 'actual-observe',
            name: 'device_observe',
            argumentsJson: '{}',
          ),
        ],
        finishReason: 'tool_calls',
      );
    } else if (calls == 2) {
      final observed =
          jsonDecode(
                messages
                    .lastWhere((m) => m.toolCallId == 'actual-observe')
                    .content,
              )
              as Map;
      expect(observed['package'], 'com.expertchat.fixture1');
      expect(observed['revision'], isA<int>());
      yield ChatChunk(
        toolCalls: [
          ToolCall(
            index: 0,
            id: 'actual-screenshot',
            name: 'device_action',
            argumentsJson: jsonEncode({
              'action': 'screenshot',
              'revision': observed['revision'],
            }),
          ),
        ],
        finishReason: 'tool_calls',
      );
    } else if (calls == 3) {
      final image = messages.singleWhere((m) => m.isToolImageObservation);
      expect(image.toolImageCallId, 'actual-screenshot');
      expect(image.imageDataUrls.single, startsWith('data:image/png;base64,'));
      final bytes = base64Decode(image.imageDataUrls.single.split(',').last);
      png = bytes;
      expect(bytes.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
      final result =
          jsonDecode(
                messages
                    .lastWhere((m) => m.toolCallId == 'actual-screenshot')
                    .content,
              )
              as Map;
      screenshot = Map<String, dynamic>.from(result['screenshot'] as Map);
      expect(screenshot!['imageWidth'], greaterThan(0));
      expect(
        screenshot!['sourceWidth'],
        greaterThanOrEqualTo(screenshot!['imageWidth']),
      );
      sawImage = true;
      yield const ChatChunk(
        contentDelta: '已通过真实设备截图观察完成隔离验收。',
        finishReason: 'stop',
      );
    } else {
      throw StateError(
        'Unexpected additional model request; no external model is configured',
      );
    }
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'fake plan traverses actual chat controller and Android screenshot to next model request',
    (tester) async {
      await tester.runAsync(() async {
        final device = DeviceAgent();
        final availableDeadline = DateTime.now().add(
          const Duration(seconds: 45),
        );
        while (!await device.available) {
          if (DateTime.now().isAfter(availableDeadline)) {
            throw StateError('Owned-AVD accessibility grant not ready');
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        // Trusted integration harness represents explicit user arming; the model
        // itself is offered only observe/action and can never arm permissions.
        await device.invoke('arm');
        try {
          const setup = 'native-chat-fixture-setup';
          var dispatched = false;
          for (var attempt = 0; attempt < 5; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            final initial = Map<String, dynamic>.from(
              await device.invoke('observe', {'sessionId': setup}) as Map,
            );
            try {
              await device.invoke('openApp', {
                'sessionId': setup,
                'revision': initial['revision'],
                'package': 'com.expertchat.fixture1',
              });
              dispatched = true;
              break;
            } on PlatformException catch (error) {
              if (error.code != 'device_action_failed' ||
                  !(error.message?.contains('Observation is stale') == true ||
                      error.message?.contains('Active window changed') ==
                          true)) {
                rethrow;
              }
            }
          }
          if (!dispatched) {
            throw StateError(
              'Fixture launch was rejected before dispatch after fresh observations',
            );
          }
          final packageDeadline = DateTime.now().add(
            const Duration(seconds: 12),
          );
          while (true) {
            final visible = Map<String, dynamic>.from(
              await device.invoke('observe', {'sessionId': setup}) as Map,
            );
            if (visible['package'] == 'com.expertchat.fixture1') break;
            if (DateTime.now().isAfter(packageDeadline)) {
              throw StateError(
                'Fixture app did not become the observed active package',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          await device.releaseSession(setup);
          SharedPreferences.setMockInitialValues({});
          FlutterSecureStorage.setMockInitialValues({});
          final db = AppDatabase(NativeDatabase.memory());
          final model = _NativePlan();
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
              settingsControllerProvider.overrideWith(
                _NativeFixtureSettings.new,
              ),
              llmProvider.overrideWithValue(model),
              sharedPrefsProvider.overrideWithValue(
                await SharedPreferences.getInstance(),
              ),
              desktopWorkspaceHostProvider.overrideWithValue(
                unsupported.createDesktopWorkspaceHost(),
              ),
              workChangesProvider.overrideWith(_TransientChanges.new),
            ],
          );
          try {
            await container.read(chatControllerProvider.future);
            final controller = container.read(chatControllerProvider.notifier);
            controller.applyComposerPrefs(
              searchMode: SearchMode.off,
              imageGenMode: ImageGenMode.off,
              reasoningEffort: ReasoningEffort.high,
            );
            controller.newConversation(workMode: true, forceNew: true);
            final id = container
                .read(chatControllerProvider)
                .requireValue
                .currentId!;
            await container
                .read(sessionPolicyProvider.notifier)
                .save(id, const SessionPolicy(approval: WorkApprovalMode.full));
            expect(
              await controller
                  .sendMessage('只观察已授权的隔离示例应用并截图；不点击、不输入、不联网。')
                  .timeout(const Duration(seconds: 45)),
              isTrue,
            );
            expect(model.calls, 3);
            expect(model.sawImage, isTrue);
            final next = await device.invoke('observe', {
              'sessionId': 'native-chat-next-task',
            });
            expect((next as Map)['package'], 'com.expertchat.fixture1');
            await device.releaseSession('native-chat-next-task');
            binding.reportData = {
              'controller_native_image_observation': true,
              'fake_model_requests': model.calls,
              'screenshot': model.screenshot,
            };
            final output = await getApplicationSupportDirectory();
            await File(
              '${output.path}/controller-native-image.png',
            ).writeAsBytes(model.png!, flush: true);
            debugPrint(
              'CONTROLLER_NATIVE_IMAGE_OK ${jsonEncode(binding.reportData)}',
            );
            await Future<void>.delayed(const Duration(milliseconds: 800));
          } finally {
            container.dispose();
            await db.close();
          }
        } finally {
          if (await device.available) await device.invoke('revoke');
          final revokedDeadline = DateTime.now().add(
            const Duration(seconds: 3),
          );
          while (await device.available &&
              DateTime.now().isBefore(revokedDeadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      });
      await tester.pump();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
