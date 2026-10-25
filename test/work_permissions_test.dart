import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/domain/desktop/command_runner.dart';
import 'package:expert_chat/domain/desktop/workspace_host_io.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/work_approvals.dart';
import 'package:expert_chat/state/model_pricing.dart';
import 'package:expert_chat/state/work_session_insights.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'widget_test.dart'
    show FakeSettings, FakeLlmProvider, InMemoryRepo, InMemoryLibraryFileStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'approval cancellation removes pending action and never approves',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final token = CancelToken();
      final pending = PendingWorkApproval(
        id: 'one',
        conversationId: 'a',
        tool: 'write',
        arguments: '{}',
        target: 'test',
        reason: '',
      );
      final decision = c
          .read(workApprovalsProvider.notifier)
          .ask(pending, token);
      expect(c.read(workApprovalsProvider), hasLength(1));
      token.cancel();
      expect(await decision, isFalse);
      expect(c.read(workApprovalsProvider), isEmpty);
    },
  );
  test(
    'cost estimation prices cached input separately and counts review requests',
    () {
      final key = modelPricingKey('test', 'model');
      final insight = WorkSessionInsights(
        pricingKeys: {'main': key, 'review': key},
        requests: {
          'main': const LlmUsage(
            inputTokens: 1000,
            outputTokens: 100,
            cachedInputTokens: 800,
          ),
          'review': const LlmUsage(inputTokens: 100, outputTokens: 10),
        },
      );
      final cost = estimateWorkCost(insight, {
        key: const ModelRate(input: 2, cached: .2, output: 8, currency: 'CNY'),
      })!;
      expect(cost.amount, closeTo(.00164, .0000001));
      expect(cost.complete, isTrue);
      expect(estimateWorkCost(insight, {}), isNull);
    },
  );
  if (!const bool.fromEnvironment('DESKTOP_WORKSPACE_NATIVE_TEST')) return;
  test(
    'local commands return real output and cancellation terminates the process',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'expert-command-test-',
      );
      addTearDown(() => root.delete());
      final output = await runWorkspaceCommand(
        Platform.isWindows ? 'Write-Output verified' : 'printf verified',
        root.path,
        const Duration(seconds: 10),
        CancelToken(),
      );
      expect(output, contains('verified'));
      final token = CancelToken();
      final running = runWorkspaceCommand(
        Platform.isWindows ? 'Start-Sleep -Seconds 30' : 'sleep 30',
        root.path,
        const Duration(seconds: 40),
        token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      token.cancel();
      expect(await running.timeout(const Duration(seconds: 5)), contains('取消'));
    },
  );
  for (final scenario in ['deny', 'approve', 'assisted', 'full']) {
    test(
      'work writes enforce $scenario before the real file operation',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final root = await Directory.systemTemp.createTemp(
          'expert-permission-test-',
        );
        final db = AppDatabase(NativeDatabase.memory());
        final host = CliDesktopWorkspaceHost(
          executable: p.absolute(
            'next',
            'target',
            'debug',
            Platform.isWindows ? 'expert-desktop.exe' : 'expert-desktop',
          ),
          dataDirectory: p.join(root.path, 'state'),
        );
        final model = FakeLlmProvider(
          const [],
          scriptedChunks: [
            [
              ChatChunk(
                toolCalls: [
                  ToolCall(
                    index: 0,
                    id: 'write',
                    name: 'coding_write_file',
                    argumentsJson: jsonEncode({
                      'scope': 'root',
                      'path': 'result.txt',
                      'content': 'approved output',
                      'expected_sha256': 'new',
                    }),
                  ),
                ],
              ),
            ],
            if (scenario == 'assisted')
              [
                const ChatChunk(
                  contentDelta: '{"approve":true,"reason":"符合用户目标"}',
                ),
              ],
            [const ChatChunk(contentDelta: '任务结束。')],
          ],
        );
        final c = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            appDatabaseProvider.overrideWithValue(db),
            libraryFileStoreProvider.overrideWithValue(
              InMemoryLibraryFileStore(),
            ),
            conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
            settingsControllerProvider.overrideWith(FakeSettings.new),
            llmProvider.overrideWithValue(model),
            desktopWorkspaceHostProvider.overrideWithValue(host),
          ],
        );
        addTearDown(() async {
          c.dispose();
          await db.close();
          if (p.basename(root.path).startsWith('expert-permission-test-') &&
              await root.parent.resolveSymbolicLinks() ==
                  await Directory.systemTemp.resolveSymbolicLinks()) {
            await root.delete(recursive: true);
          }
        });
        await c.read(chatControllerProvider.future);
        final ctrl = c.read(chatControllerProvider.notifier);
        ctrl.newConversation(workMode: true, forceNew: true);
        final id = c.read(chatControllerProvider).requireValue.currentId!;
        await c
            .read(sessionPolicyProvider.notifier)
            .save(
              id,
              SessionPolicy(
                network: false,
                approval: scenario == 'assisted'
                    ? WorkApprovalMode.assisted
                    : scenario == 'full'
                    ? WorkApprovalMode.full
                    : WorkApprovalMode.request,
                reviewerModel: scenario == 'assisted' ? 'review-model' : '',
              ),
            );
        final workspace = await host.defaultWorkspace();
        final file = File(p.join(workspace.root, 'result.txt'));
        final pending = Completer<PendingWorkApproval>();
        final subscription = c.listen(workApprovalsProvider, (_, v) {
          if (v.isNotEmpty && !pending.isCompleted) pending.complete(v.first);
        });
        addTearDown(subscription.close);
        final sending = ctrl.sendMessage('创建 result.txt');
        if (scenario == 'deny' || scenario == 'approve') {
          final request = await pending.future.timeout(
            const Duration(seconds: 10),
          );
          expect(await file.exists(), isFalse);
          c
              .read(workApprovalsProvider.notifier)
              .decide(request.id, scenario == 'approve');
        }
        await sending.timeout(const Duration(seconds: 15));
        expect(await file.exists(), scenario != 'deny');
        if (scenario == 'assisted') {
          expect(model.configs[1].model, 'review-model');
          expect(model.toolCalls[1], isNull);
        }
        expect(c.read(workApprovalsProvider), isEmpty);
      },
    );
  }
}
