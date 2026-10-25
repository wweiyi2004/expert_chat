/// Only host-observed structured results are evidence. Model prose is not proof.
enum TaskAcceptanceStatus {
  running,
  replyComplete,
  toolComplete,
  waitingAcceptance,
  accepted,
  failed,
}

class AcceptanceCriteria {
  AcceptanceCriteria({
    this.description = '',
    List<String> checkIds = const [],
    List<String> artifactPaths = const [],
    this.manualRequired = true,
  }) : checkIds = List.unmodifiable(checkIds),
       artifactPaths = List.unmodifiable(artifactPaths);
  final String description;
  final List<String> checkIds, artifactPaths;
  final bool manualRequired;
  Map<String, dynamic> toJson() => {
    'description': description,
    'checkIds': checkIds,
    'artifactPaths': artifactPaths,
    'manualRequired': manualRequired,
  };
  factory AcceptanceCriteria.fromJson(Map<String, dynamic> j) =>
      AcceptanceCriteria(
        description: j['description'] as String? ?? '',
        checkIds: (j['checkIds'] as List? ?? []).cast<String>(),
        artifactPaths: (j['artifactPaths'] as List? ?? []).cast<String>(),
        manualRequired: j['manualRequired'] as bool? ?? true,
      );
}

class TaskAcceptance {
  TaskAcceptance({
    required this.taskId,
    this.conversationId = '',
    required this.criteria,
    DateTime? frozenAt,
  }) : frozenAt = frozenAt ?? DateTime.now();
  final String taskId;
  final String conversationId;
  final AcceptanceCriteria criteria;
  final DateTime frozenAt;
  bool replyComplete = false, toolsComplete = false, manuallyAccepted = false;
  int mutationRevision = 0;

  /// Imported evidence is historical; never current-machine verification.
  bool requiresReverification = false;
  String? acceptedBy;
  DateTime? acceptedAt;
  final Map<String, Map<String, dynamic>> _checks = {}, _artifacts = {};
  Map<String, Map<String, dynamic>> get checks => Map.unmodifiable(
    _checks.map((k, v) => MapEntry(k, Map<String, dynamic>.unmodifiable(v))),
  );
  Map<String, Map<String, dynamic>> get artifacts => Map.unmodifiable(
    _artifacts.map((k, v) => MapEntry(k, Map<String, dynamic>.unmodifiable(v))),
  );
  bool get hasFailure =>
      _checks.values.any((v) => v['exitCode'] != 0) ||
      _artifacts.values.any(
        (v) => v['present'] != true || (v['sha256'] as String? ?? '').isEmpty,
      );
  bool get machineVerified =>
      !requiresReverification &&
      !hasFailure &&
      criteria.checkIds.every((id) => _checks[id]?['exitCode'] == 0) &&
      criteria.artifactPaths.every(
        (path) =>
            _artifacts[path]?['present'] == true &&
            (_artifacts[path]?['sha256'] as String? ?? '').isNotEmpty,
      );
  TaskAcceptanceStatus get status {
    if (hasFailure) return TaskAcceptanceStatus.failed;
    if (replyComplete &&
        toolsComplete &&
        machineVerified &&
        ((!criteria.manualRequired &&
                (criteria.checkIds.isNotEmpty ||
                    criteria.artifactPaths.isNotEmpty)) ||
            manuallyAccepted)) {
      return TaskAcceptanceStatus.accepted;
    }
    if (replyComplete && toolsComplete) {
      return TaskAcceptanceStatus.waitingAcceptance;
    }
    if (toolsComplete) return TaskAcceptanceStatus.toolComplete;
    if (replyComplete) return TaskAcceptanceStatus.replyComplete;
    return TaskAcceptanceStatus.running;
  }

  void recordCheck({
    required String id,
    required int exitCode,
    required String invocationId,
    required String provenance,
  }) {
    if (!criteria.checkIds.contains(id)) {
      throw ArgumentError('Check must be frozen before execution');
    }
    if (invocationId.isEmpty || provenance.isEmpty) {
      throw ArgumentError('Host observation provenance required');
    }
    _invalidateApproval();
    _checks[id] = {
      'exitCode': exitCode,
      'invocationId': invocationId,
      'provenance': provenance,
      'observedAt': DateTime.now().toIso8601String(),
    };
  }

  void recordArtifact({
    required String path,
    required bool present,
    required String sha256,
    required String provenance,
  }) {
    if (!criteria.artifactPaths.contains(path)) {
      throw ArgumentError('Artifact must be frozen before execution');
    }
    if (provenance.isEmpty ||
        (present && !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256))) {
      throw ArgumentError('Observed SHA-256 and provenance required');
    }
    final previous = _artifacts[path];
    if (!present || (previous != null && previous['sha256'] != sha256)) {
      _checks.clear();
    }
    _invalidateApproval();
    _artifacts[path] = {
      'present': present,
      'sha256': sha256,
      'provenance': provenance,
      'observedAt': DateTime.now().toIso8601String(),
    };
  }

  void invalidateCheck(String id) {
    _checks.remove(id);
    _invalidateApproval();
  }

  /// Any workspace mutation makes earlier check results and user approval stale.
  void invalidateAfterMutation() {
    mutationRevision++;
    _checks.clear();
    _artifacts.clear();
    _invalidateApproval();
  }

  void _invalidateApproval() {
    manuallyAccepted = false;
    acceptedBy = null;
    acceptedAt = null;
  }

  void acceptByUser(String actor) {
    if (!replyComplete ||
        !toolsComplete ||
        !machineVerified ||
        actor.trim().isEmpty) {
      throw StateError(
        'Acceptance requires finished execution and all frozen evidence',
      );
    }
    manuallyAccepted = true;
    acceptedBy = actor;
    acceptedAt = DateTime.now();
  }

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'conversationId': conversationId,
    'mutationRevision': mutationRevision,
    'requiresReverification': requiresReverification,
    'criteria': criteria.toJson(),
    'frozenAt': frozenAt.toIso8601String(),
    'replyComplete': replyComplete,
    'toolsComplete': toolsComplete,
    'manuallyAccepted': manuallyAccepted,
    'acceptedBy': acceptedBy,
    'acceptedAt': acceptedAt?.toIso8601String(),
    'checks': _checks,
    'artifacts': _artifacts,
  };
  factory TaskAcceptance.fromJson(Map<String, dynamic> j) {
    final t = TaskAcceptance(
      taskId: j['taskId'] as String,
      conversationId: j['conversationId'] as String? ?? '',
      criteria: AcceptanceCriteria.fromJson(
        Map<String, dynamic>.from(j['criteria'] as Map),
      ),
      frozenAt: DateTime.parse(j['frozenAt'] as String),
    );
    t.requiresReverification = j['requiresReverification'] == true;
    t.mutationRevision = (j['mutationRevision'] as num?)?.toInt() ?? 0;
    t.replyComplete = j['replyComplete'] == true;
    t.toolsComplete = j['toolsComplete'] == true;
    t.manuallyAccepted = j['manuallyAccepted'] == true;
    t.acceptedBy = j['acceptedBy'] as String?;
    t.acceptedAt = DateTime.tryParse(j['acceptedAt'] as String? ?? '');
    for (final entry in Map<String, dynamic>.from(
      j['checks'] as Map? ?? {},
    ).entries) {
      t._checks[entry.key] = Map<String, dynamic>.from(entry.value as Map);
    }
    for (final entry in Map<String, dynamic>.from(
      j['artifacts'] as Map? ?? {},
    ).entries) {
      t._artifacts[entry.key] = Map<String, dynamic>.from(entry.value as Map);
    }
    return t;
  }
}
