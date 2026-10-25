import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/tools/math/math_toolkit.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/tool_registry_settings.dart';
import 'package:expert_chat/state/work_runtime_logs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart' show FakeSettings, FakeLlmProvider;

class _Math extends MathToolkit {
  _Math(this.run);
  final Future<Map<String, dynamic>> Function(
    Map<String, dynamic>,
    CancelToken?,
  )
  run;
  @override
  Future<Map<String, dynamic>> execute(
    Map<String, dynamic> arguments, {
    CancelToken? cancelToken,
  }) => run(arguments, cancelToken);
}

class _Options extends ToolRegistrySettings {
  _Options(this.math) : super(mathEnabled: true);
  final MathToolkit math;
  @override
  MathToolkit get mathematics => math;
}

class _Registry extends ToolRegistryController {
  _Registry(this.math);
  final MathToolkit math;
  @override
  ToolRegistrySettings build() => _Options(math);
}

ChatChunk _call(String? id, String name, Map<String, dynamic> args) =>
    ChatChunk(
      toolCalls: [
        ToolCall(index: 0, id: id, name: name, argumentsJson: jsonEncode(args)),
      ],
      finishReason: 'tool_calls',
    );

class _ParallelLlm implements LlmProvider {
  _ParallelLlm(this.finished);
  final Completer<void> finished;
  var rootStarted = false;
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
    if (tools == null || tools.isEmpty) {
      yield const ChatChunk(
        contentDelta: '{"role":"general","confidence":1}',
        finishReason: 'stop',
      );
      return;
    }
    final child = messages.any(
      (m) =>
          m.role == MessageRole.user &&
          (m.content == 'parallel-alpha' || m.content == 'parallel-beta'),
    );
    if (!child) {
      if (!rootStarted) {
        rootStarted = true;
        yield ChatChunk(
          toolCalls: [
            for (var i = 0; i < 2; i++)
              ToolCall(
                index: i,
                id: 'spawn-$i',
                name: 'work_spawn_agent',
                argumentsJson: jsonEncode({
                  'task': i == 0 ? 'parallel-alpha' : 'parallel-beta',
                  'read_only': true,
                }),
              ),
          ],
          finishReason: 'tool_calls',
        );
      } else {
        await finished.future;
        yield const ChatChunk(
          contentDelta: 'Both children complete.',
          finishReason: 'stop',
        );
      }
      return;
    }
    final results = messages.where((m) => m.role == MessageRole.tool).toList();
    if (!results.any((m) => m.toolCallId == 'activate-math')) {
      yield _call('activate-math', 'tool_registry_request', {
        'tools': ['math_calculate'],
      });
    } else if (!results.any((m) => m.toolCallId == 'same-math-id')) {
      yield _call('same-math-id', 'math_calculate', {
        'operation': 'exact',
        'expression': '1+1',
      });
    } else {
      yield const ChatChunk(contentDelta: 'Child done.', finishReason: 'stop');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'concurrent child math calls with identical arguments retain their own host activity result',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      final repository = DriftConversationRepository(db);
      final secondEntered = Completer<void>();
      final bothReturned = Completer<void>();
      var calls = 0;
      final math = _Math((args, token) async {
        final ordinal = ++calls;
        if (ordinal == 1) {
          await secondEntered.future.timeout(const Duration(seconds: 5));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          bothReturned.complete();
        } else {
          secondEntered.complete();
        }
        return {
          'ok': true,
          'result': {'exact': '$ordinal'},
        };
      });
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          toolRegistrySettingsProvider.overrideWith(() => _Registry(math)),
          desktopWorkspaceHostProvider.overrideWithValue(
            stub.createDesktopWorkspaceHost(),
          ),
          llmProvider.overrideWithValue(_ParallelLlm(bothReturned)),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await container.read(chatControllerProvider.future);
      final controller = container.read(chatControllerProvider.notifier);
      controller.applyComposerPrefs(
        searchMode: SearchMode.off,
        imageGenMode: ImageGenMode.off,
        reasoningEffort: ReasoningEffort.high,
      );
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      await controller
          .sendMessage('Parent: run two independent calculations.')
          .timeout(const Duration(seconds: 12));
      expect(calls, 2);
      final steps = container
          .read(chatControllerProvider)
          .requireValue
          .current!
          .messages
          .last
          .searchActivities
          .where((s) => s.toolName == 'math_calculate')
          .toList();
      expect(steps, hasLength(2));
      expect(steps.map((s) => s.id).toSet(), hasLength(2));
      expect(steps.map((s) => s.toolArguments).toSet(), hasLength(1));
      // Child runtime assigns distinct host call IDs even when provider IDs repeat.
      expect(steps.map((s) => s.toolCallId).toSet(), hasLength(2));
      expect(
        steps.map((s) => jsonDecode(s.resultText!)['result']['exact']).toSet(),
        {'1', '2'},
      );
      expect(steps.every((s) => s.status == SearchActivityStatus.done), isTrue);
      final reloaded = await DriftConversationRepository(
        db,
      ).loadConversation(id);
      expect(
        reloaded.messages.last.searchActivities
            .where((s) => s.toolName == 'math_calculate')
            .map((s) => jsonDecode(s.resultText!)['result']['exact'])
            .toSet(),
        {'1', '2'},
      );
    },
  );
  for (final outcome in [
    'success',
    'inconclusive',
    'backend_failure',
    'throw',
    'cancel',
    'not_active',
    'null_id',
    'denied',
    'unknown',
  ]) {
    test(
      'controller registry math lifecycle $outcome persists exact call identity and safe arguments',
      () async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase(NativeDatabase.memory());
        final repository = DriftConversationRepository(db);
        final entered = Completer<void>();
        var executed = 0;
        final math = _Math((args, token) async {
          executed++;
          if (!entered.isCompleted) entered.complete();
          if (outcome == 'throw') throw StateError('fixture backend failure');
          if (outcome == 'cancel') {
            await token!.whenCancel;
            throw token.cancelError!;
          }
          if (outcome == 'unknown') return {'execution_outcome': 'unknown'};
          if (outcome == 'backend_failure') {
            return {'ok': false, 'error': 'invalid expression'};
          }
          if (outcome == 'inconclusive') {
            return {
              'ok': true,
              'backend': 'SymPy',
              'result': {
                'equal': null,
                'residual': {'exact': 'x - 1'},
              },
            };
          }
          // Use the actual trusted worker, not a fabricated numeric success.
          return MathToolkit().execute(args, cancelToken: token);
        });
        final llm = FakeLlmProvider(
          const [],
          scriptedChunks: [
            [
              _call('discover', 'tool_registry_search', {
                'query': 'math_calculate',
              }),
            ],
            if (outcome != 'not_active')
              [
                _call('request', 'tool_registry_request', {
                  'tools': [
                    outcome == 'denied'
                        ? 'unconfigured_tool'
                        : 'math_calculate',
                  ],
                }),
              ],
            [
              _call(
                outcome == 'null_id' ? null : 'math-call',
                'math_calculate',
                {
                  'operation': outcome == 'inconclusive' ? 'verify' : 'exact',
                  'expression': '1/3+1/6',
                  'api_key': 'must-not-persist',
                },
              ),
            ],
            if (outcome == 'success')
              [
                _call('math-call', 'math_calculate', {
                  'operation': 'exact',
                  'expression': '2+3',
                }),
              ],
            [const ChatChunk(contentDelta: 'finished', finishReason: 'stop')],
          ],
        );
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            appDatabaseProvider.overrideWithValue(db),
            conversationRepositoryProvider.overrideWithValue(repository),
            settingsControllerProvider.overrideWith(FakeSettings.new),
            toolRegistrySettingsProvider.overrideWith(() => _Registry(math)),
            desktopWorkspaceHostProvider.overrideWithValue(
              stub.createDesktopWorkspaceHost(),
            ),
            llmProvider.overrideWithValue(llm),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await db.close();
        });
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
        final sent = controller.sendMessage(
          'Calculate using the configured mathematics tool.',
        );
        if (outcome == 'cancel') {
          await entered.future.timeout(const Duration(seconds: 5));
          controller.stop(conversationId: id);
        }
        await sent.timeout(const Duration(seconds: 15));
        final assistant = container
            .read(chatControllerProvider)
            .requireValue
            .conversations
            .firstWhere((c) => c.id == id)
            .messages
            .last;
        final mathSteps = assistant.searchActivities
            .where((a) => a.toolName == 'math_calculate')
            .toList();
        expect(mathSteps, hasLength(outcome == 'success' ? 2 : 1));
        final step = mathSteps.first;
        expect(
          step.toolCallId,
          outcome == 'null_id' ? startsWith('call_0_') : 'math-call',
        );
        expect(jsonDecode(step.toolArguments!)['expression'], '1/3+1/6');
        expect(jsonDecode(step.toolArguments!)['api_key'], '[redacted]');
        expect(step.toolArguments, isNot(contains('must-not-persist')));
        expect(
          step.status,
          ['success', 'inconclusive', 'null_id'].contains(outcome)
              ? SearchActivityStatus.done
              : SearchActivityStatus.failed,
        );
        expect(step.finishedAt, isNotNull);
        if (outcome == 'success') {
          expect(jsonDecode(step.resultText!)['result']['exact'], '1/2');
          expect(mathSteps.map((s) => s.id).toSet(), hasLength(2));
          expect(
            jsonDecode(mathSteps.last.resultText!)['result']['exact'],
            '5',
          );
        }
        if (outcome == 'inconclusive') {
          expect(jsonDecode(step.resultText!)['result']['equal'], isNull);
        }
        expect(
          executed,
          ['not_active', 'denied'].contains(outcome)
              ? 0
              : outcome == 'success'
              ? 2
              : 1,
        );
        final terminal = container
            .read(workRuntimeLogsProvider)
            .where(
              (e) =>
                  e.conversationId == id &&
                  e.toolCallId == step.toolCallId &&
                  e.phase == 'tool' &&
                  e.status != 'started',
            )
            .toList();
        expect(terminal.last.status, switch (outcome) {
          'success' || 'inconclusive' || 'null_id' => 'completed',
          'unknown' => 'unknown',
          'cancel' => 'cancelled',
          'not_active' || 'denied' => 'skipped',
          _ => 'failed',
        });
        if (outcome == 'denied') {
          expect(
            container
                .read(workRuntimeLogsProvider)
                .where(
                  (e) =>
                      e.conversationId == id &&
                      e.toolCallId == 'request' &&
                      e.status == 'denied',
                ),
            hasLength(1),
          );
        }
        // Reload using a fresh real SQLite adapter, not the live controller state.
        final saved = await DriftConversationRepository(
          db,
        ).loadConversation(id);
        final reloaded = saved.messages.last.searchActivities.firstWhere(
          (s) => s.id == step.id,
        );
        expect(reloaded.toolCallId, step.toolCallId);
        expect(reloaded.toolArguments, step.toolArguments);
        expect(reloaded.status, step.status);
      },
    );
  }
}
