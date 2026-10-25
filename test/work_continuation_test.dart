import 'dart:async';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/work_rounds.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _NoModel extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState();
}

class _GateLlm implements LlmProvider {
  int calls = 0;
  final entered = Completer<void>();
  final chunks = StreamController<ChatChunk>.broadcast();
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) {
    calls++;
    if (calls > 1) {
      return Stream.value(
        const ChatChunk(contentDelta: 'normal', finishReason: 'stop'),
      );
    }
    if (!entered.isCompleted) entered.complete();
    return chunks.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final configured in [true, false]) {
    test(
      'work continuation preserves root allowance and never changes configured policy, configured=$configured',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase(NativeDatabase.memory());
        final work = Conversation(id: 'work', title: 'work', workMode: true);
        final other = Conversation(id: 'other', title: 'other');
        final repo = InMemoryRepo()..store = [work, other];
        final llm = _GateLlm();
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            appDatabaseProvider.overrideWithValue(db),
            conversationRepositoryProvider.overrideWithValue(repo),
            desktopWorkspaceHostProvider.overrideWithValue(
              stub.createDesktopWorkspaceHost(),
            ),
            settingsControllerProvider.overrideWith(
              configured ? FakeSettings.new : _NoModel.new,
            ),
            llmProvider.overrideWithValue(llm),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await Future<void>.delayed(Duration.zero);
          await llm.chunks.close();
          await db.close();
        });
        await container.read(settingsControllerProvider.future);
        await container.read(chatControllerProvider.future);
        final controller = container.read(chatControllerProvider.notifier);
        await controller.selectConversation('other');
        await container
            .read(sessionPolicyProvider.notifier)
            .save(
              'work',
              const SessionPolicy(
                toolRounds: 12,
                roundExtension: 5,
                network: false,
              ),
            );
        final originalPolicyBytes = prefs.getString('sessionPolicies');
        final originalPolicy = container
            .read(sessionPolicyProvider)['work']!
            .toJson();
        String? originalRoot;
        if (configured) {
          await controller.selectConversation('work');
          llm.calls = 1;
          expect(
            await controller.sendMessage('original authorized task'),
            isTrue,
          );
          originalRoot =
              controller.taskSnapshotFor('work')!['rootId'] as String;
          llm.calls = 0;
          await controller.selectConversation('other');
        } else {
          container
              .read(workRoundsProvider.notifier)
              .start('work', 'old', const SessionPolicy());
          container
              .read(workRoundsProvider.notifier)
              .update('work', 'old', (p) => p.copyWith(active: false));
        }
        expect(await controller.sendWorkContinuation('other', 5), isFalse);
        expect(await controller.sendWorkContinuation('work', 0), isFalse);
        expect(await controller.sendWorkContinuation('work', 1001), isFalse);
        final sent = controller.sendWorkContinuation('work', 5);
        if (configured) {
          await llm.entered.future.timeout(const Duration(seconds: 10));
          expect(container.read(workRoundsProvider)['work']!.limit, 17);
          expect(controller.taskSnapshotFor('work')!['rootId'], originalRoot);
          expect(
            container.read(chatControllerProvider).requireValue.currentId,
            'other',
          );
          expect(await controller.sendWorkContinuation('work', 5), isFalse);
          await controller.selectConversation('work');
          await controller.selectConversation('other');
          llm.chunks.add(
            const ChatChunk(contentDelta: 'continued', finishReason: 'stop'),
          );
          await llm.chunks.close();
          expect(await sent, isTrue);
          final state = container.read(chatControllerProvider).requireValue;
          expect(state.currentId, 'other');
          expect(
            state.conversations.firstWhere((c) => c.id == 'other').messages,
            isEmpty,
          );
          expect(
            state.conversations
                .firstWhere((c) => c.id == 'work')
                .messages
                .where((m) => m.role == MessageRole.user)
                .last
                .content,
            '继续完成任务，增加 5 轮。',
          );
        } else {
          expect(await sent, isFalse);
          expect(llm.entered.isCompleted, isFalse);
          expect(container.read(workRoundsProvider)['work']!.runId, 'old');
        }
        expect(container.read(sessionPolicyProvider)['work']!.toolRounds, 12);
        expect(
          container.read(sessionPolicyProvider)['work']!.roundExtension,
          5,
        );
        expect(prefs.getString('sessionPolicies'), originalPolicyBytes);
        expect(
          container.read(sessionPolicyProvider)['work']!.toJson(),
          originalPolicy,
        );
        if (configured) {
          await controller.selectConversation('work');
          expect(await controller.sendMessage('正常下一轮'), isTrue);
          expect(container.read(workRoundsProvider)['work']!.limit, 12);
          expect(prefs.getString('sessionPolicies'), originalPolicyBytes);
        }
      },
    );
  }
}
