part of '../chat_controller.dart';

// Every accepted entry point carries this value through its asynchronous work.
// Selection belongs to the UI; a run's identity never follows UI selection.
final Object _sessionZoneKey = Object();

class _SessionConfiguration {
  const _SessionConfiguration({
    required this.policy,
    required this.workspaceId,
    required this.modelChoice,
    required this.thinking,
    required this.effort,
    required this.settings,
    required this.mcpServerIds,
    required this.servicePriorities,
    this.credentialEpochs = const {},
    this.routeSignature = '',
  });
  final SessionPolicy policy;
  final String? workspaceId;
  final String? modelChoice;
  final bool thinking;
  final ReasoningEffort effort;
  final SettingsState? settings;
  final List<String> mcpServerIds;
  final Map<String, List<String>> servicePriorities;
  final Map<String, int> credentialEpochs;
  final String routeSignature;

  List<String> changesFrom(_SessionConfiguration other) => [
    if (modelChoice != other.modelChoice ||
        settings?.model != other.settings?.model ||
        settings?.activeProfileId != other.settings?.activeProfileId ||
        settings?.baseUrl != other.settings?.baseUrl ||
        settings?.profiles != other.settings?.profiles ||
        !identical(servicePriorities, other.servicePriorities))
      '模型',
    if (jsonEncode(credentialEpochs) != jsonEncode(other.credentialEpochs) ||
        ((settings?.active?.authMode ?? 'apiKey') == 'apiKey' &&
            (other.settings?.active?.authMode ?? 'apiKey') == 'apiKey' &&
            settings?.apiKey != other.settings?.apiKey))
      '模型凭据',
    if (routeSignature != other.routeSignature) '模型路由',

    if (thinking != other.thinking || effort != other.effort) '思考',
    if (workspaceId != other.workspaceId ||
        policy.sshProfileId != other.policy.sshProfileId ||
        policy.remoteRoot != other.policy.remoteRoot)
      '工作区',
    if (settings?.context != other.settings?.context ||
        settings?.modelContexts != other.settings?.modelContexts)
      '上下文',
    if (settings?.taskBudget.workResponseTimeoutSeconds !=
        other.settings?.taskBudget.workResponseTimeoutSeconds)
      '响应等待',
    if (settings?.searchApiKey != other.settings?.searchApiKey ||
        settings?.searchBackend != other.settings?.searchBackend)
      '搜索',
    if (settings?.workAgentInstructions !=
        other.settings?.workAgentInstructions)
      '主代理指令',
    if (settings?.subagentInstructions != other.settings?.subagentInstructions)
      '子代理指令',
    if (settings?.subagentRoles != other.settings?.subagentRoles ||
        settings?.subagentRouterModel != other.settings?.subagentRouterModel)
      '子代理角色',
    if (policy.network != other.policy.network ||
        policy.planOnly != other.policy.planOnly ||
        policy.approval != other.policy.approval ||
        policy.reviewerModel != other.policy.reviewerModel)
      '权限',
    if (mcpServerIds.join('\u0000') != other.mcpServerIds.join('\u0000') ||
        settings?.gateway != other.settings?.gateway)
      '工具',
  ];
}

class _SessionEvent {
  const _SessionEvent(this.id, this.content, this.taskId);
  final String id;
  final String content;
  final String? taskId;
}

class _SessionRun {
  _SessionRun(this.conversationId);
  final String conversationId;
  final execution = GenerationExecution();
  _SessionConfiguration? configuration;
  String? streamingId;
  String? currentRoundId;
  TaskCore? core;
  String? taskId;
  String? agentRootId;
  String? agentTaskId;
  String originatingUserGoal = '';
  CancelToken taskCancellation = CancelToken();
  void Function(bool)? sharedExecution;
  int activeChildren = 0;
  bool resumingAgentTree = false;
  bool searching = false;
  bool generatingImage = false;
  bool processingDocument = false;
  bool followingTail = true;
  bool thinkingExpanded = true;
  bool hasLiveContent = false;
  bool userCancelled = false;
  bool awaitingEvents = false;
  bool wakeScheduled = false;
  void Function()? flush;
  void Function()? nudge;
  final List<_SessionEvent> inbox = [];
  final Set<String> receivedEventIds = {};
  final Set<String> cancelledTaskIds = {};
  final Set<String> acceptedTaskIds = {};
}

class _SessionFailure {
  const _SessionFailure(this.message, this.retry, {this.dismissed = false});
  final String message;
  final ChatRetryOperation? retry;
  final bool dismissed;
}

/// No preference values or platform exception text enter user-facing errors.
class _SessionJournalFailure implements Exception {
  const _SessionJournalFailure(this.revision, this.reason);
  final int revision;
  final String reason;
  @override
  String toString() => '检查点版本 $revision 持久化失败（3 次，$reason）';
}
