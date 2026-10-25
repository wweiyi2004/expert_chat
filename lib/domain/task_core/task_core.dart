/// Durable, framework-independent task lineage and event inbox.
/// Events are acknowledged only after their context record is durably saved.
class TaskCore {
  TaskCore({required this.rootId, this.goal = '', this.resumeRequired = false});
  final String rootId;
  String goal;
  String? agentTaskId;
  String? agentRootId;
  bool resumeRequired;
  bool cancelled = false;
  final Map<String, Map<String, dynamic>> inbox = {};
  final Set<String> acknowledged = {};
  final Set<String> lineage = {};
  Map<String, dynamic> target = {};
  Map<String, dynamic> repositorySources = {};
  Map<String, dynamic> budget = {};
  Map<String, dynamic> rounds = {};
  bool receive(String id, String content, String? taskId) {
    if (cancelled || acknowledged.contains(id) || inbox.containsKey(id)) {
      return false;
    }
    inbox[id] = {'id': id, 'content': content, 'taskId': taskId};
    return true;
  }

  void acknowledge(Iterable<String> ids) {
    for (final id in ids) {
      if (inbox.remove(id) != null) acknowledged.add(id);
    }
  }

  void cancel() {
    cancelled = true;
    resumeRequired = false;
    inbox.clear();
  }

  Map<String, dynamic> toJson() => {
    'agentRootId': agentRootId,
    'agentTaskId': agentTaskId,
    'target': target,
    'repositorySources': repositorySources,
    'repositoryContext': repositorySources['main'],
    'version': 1,
    'rootId': rootId,
    'goal': goal,
    'cancelled': cancelled,
    'resumeRequired': resumeRequired,
    'inbox': inbox.values.toList(),
    'acknowledged': acknowledged.toList(),
    'lineage': lineage.toList(),
    'budget': budget,
    'rounds': rounds,
  };
  factory TaskCore.fromJson(
    Map<String, dynamic> json, {
    bool interrupted = true,
  }) {
    final core = TaskCore(
      rootId: json['rootId'] as String,
      goal: json['goal'] as String? ?? '',
      resumeRequired: interrupted || json['resumeRequired'] == true,
    );
    core.agentRootId = json['agentRootId'] as String?;
    core.agentTaskId = json['agentTaskId'] as String?;
    core.target = Map<String, dynamic>.from(json['target'] as Map? ?? {});
    core.repositorySources = Map<String, dynamic>.from(
      json['repositorySources'] as Map? ?? {},
    );
    core.cancelled = json['cancelled'] == true;
    if (core.cancelled) core.resumeRequired = false;
    for (final item in json['inbox'] as List? ?? const []) {
      final event = Map<String, dynamic>.from(item as Map);
      core.inbox[event['id'] as String] = event;
    }
    core.acknowledged.addAll(
      (json['acknowledged'] as List? ?? const []).cast<String>(),
    );
    core.lineage.addAll((json['lineage'] as List? ?? const []).cast<String>());
    core.budget = Map<String, dynamic>.from(json['budget'] as Map? ?? {});
    core.rounds = Map<String, dynamic>.from(json['rounds'] as Map? ?? {});
    return core;
  }
}
