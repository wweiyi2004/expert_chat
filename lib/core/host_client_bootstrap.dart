import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import '../platform/preferences.dart';
import '../platform/host_client_stores.dart';
import '../platform/host_client_paths.dart';
import '../data/db/app_database.dart';
import '../domain/host/host_client.dart';
import '../domain/host/reconnecting_database.dart';
import '../domain/host/workspace_client.dart';
import '../domain/host/runtime_projection.dart';
import '../domain/host/llm_client.dart';
import '../state/chat_controller.dart';
import '../state/settings_controller.dart';
import '../state/host_chat_controller.dart';
import '../state/host_settings_controller.dart';
import '../state/host_runtime_providers.dart';
import '../state/work_approvals.dart';
import '../state/work_questions.dart';
import '../state/work_rounds.dart';
import '../state/work_changes.dart';
import '../state/work_task_runtime.dart';
import '../state/work_runtime_logs.dart';
import '../state/task_acceptance_provider.dart';
import '../state/task_plans.dart';
import '../state/research_terminal_controller.dart';
import '../state/host_research_terminal.dart';
import '../state/session_policy.dart';
import '../state/conversation_model_choice.dart';
import '../state/conversation_workspace_bindings.dart';
import '../state/work_agents.dart';
import '../state/work_processes.dart';
import '../state/work_memory.dart';
import '../state/role_evolution.dart';
import '../state/work_session_insights.dart';
import '../state/work_task_steering.dart';
import 'providers.dart';
import 'desktop_providers.dart';
import '../features/shell/host_gui_actions.dart';

class HostClientBootstrap {
  HostClientBootstrap._(this.client, this.database, this.preferences);
  final HostClient client;
  final AppDatabase database;
  final SharedPreferences preferences;
  static Future<HostClientBootstrap> open() async {
    final client = await HostClient.attachDefault();
    installHostProfilePaths(client.dataDirectory);
    final prefs = HostPreferenceStore(client);
    await prefs.refresh();
    SharedPreferencesStorePlatform.instance = prefs;
    FlutterSecureStoragePlatform.instance = HostCredentialStore(client);
    final connection = ReconnectingHostDatabase(client);
    final database = AppDatabase(connection.connection);
    connection.tableNames = database.allTables
        .map((t) => t.actualTableName)
        .toSet();
    return HostClientBootstrap._(
      client,
      database,
      await SharedPreferences.getInstance(),
    );
  }

  Widget wrap(Widget child) => ProviderScope(
    overrides: [
      sharedPrefsProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      chatControllerProvider.overrideWith(HostChatController.new),
      settingsControllerProvider.overrideWith(HostSettingsController.new),
      llmProvider.overrideWithValue(HostLlmProvider(client)),
      desktopWorkspaceHostProvider.overrideWithValue(
        HostWorkspaceClient(client),
      ),
      libraryFileStoreProvider.overrideWithValue(HostLibraryFiles(client)),
      memoryStoreProvider.overrideWithValue(HostMemoryFiles(client)),
      workApprovalsProvider.overrideWith(HostWorkApprovals.new),
      workQuestionsProvider.overrideWith(HostWorkQuestions.new),
      workRoundsProvider.overrideWith(HostWorkRounds.new),
      workChangesProvider.overrideWith(HostWorkChanges.new),
      workTaskRuntimeProvider.overrideWith(HostTaskRuntime.new),
      workRuntimeLogsProvider.overrideWith(HostRuntimeLogs.new),
      taskAcceptanceProvider.overrideWith(HostAcceptanceStore.new),
      sessionPolicyProvider.overrideWith(HostSessionPolicies.new),
      taskPlansProvider.overrideWith(HostTaskPlans.new),
      researchTerminalProvider.overrideWith(HostResearchTerminalController.new),
      conversationModelChoiceProvider.overrideWith(
        HostConversationModelChoice.new,
      ),
      conversationWorkspaceBindingsProvider.overrideWith(
        HostWorkspaceBindings.new,
      ),
      workAgentModelPoolProvider.overrideWith(HostAgentModelPool.new),
      roleEvolutionProvider.overrideWith(HostRoleEvolution.new),
      workSessionInsightsProvider.overrideWith(HostWorkInsights.new),
      modelUsageControllerProvider.overrideWith(HostModelUsage.new),
      workTaskSteeringProvider.overrideWith((ref) {
        var signature = jsonEncode(hostRuntime()['steering']);
        final subscription = client.updates.listen((event) {
          final next = jsonEncode(hostRuntime()['steering']);
          if (next != signature && ref.mounted) {
            signature = next;
            ref.invalidateSelf();
          }
        });
        ref.onDispose(subscription.cancel);
        return HostTaskSteering();
      }),
      workMemoryProvider.overrideWith((ref) {
        var signature = jsonEncode(hostRuntime()['memory']);
        final subscription = client.updates.listen((event) {
          final next = jsonEncode(hostRuntime()['memory']);
          if (next != signature && ref.mounted) {
            signature = next;
            ref.invalidateSelf();
          }
        });
        ref.onDispose(subscription.cancel);
        return HostWorkMemory();
      }),
      workAgentsProvider.overrideWith((ref) {
        final runtime = HostAgentRuntime();
        ref.onDispose(runtime.dispose);
        return runtime;
      }),
      workProcessesProvider.overrideWith((ref) {
        final runtime = HostProcessRuntime();
        ref.onDispose(runtime.dispose);
        return runtime;
      }),
      workHooksProvider.overrideWith((ref) {
        final runtime = HostHookRuntime(ref.read(workProcessesProvider));
        ref.onDispose(runtime.dispose);
        return runtime;
      }),
    ],
    child: HostGuiActions(child: child),
  );
}
