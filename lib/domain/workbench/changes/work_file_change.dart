import 'dart:convert';

/// A session's file snapshot. [target] identifies the original execution host;
/// restoring must never silently substitute the currently selected workspace.
class WorkFileChange {
  const WorkFileChange({
    required this.id,
    required this.conversationId,
    required this.target,
    required this.scope,
    required this.path,
    required this.before,
    required this.after,
    required this.beforeHash,
    required this.afterHash,
    required this.updatedAt,
    this.reverted = false,
    this.assistantId = '',
    this.beforeKnown = true,
    this.deliveryHash,
    this.roundId = '',
    this.artifactManifest,
    this.recreateNewFile = false,
    this.textSnapshot = true,
    this.deleted = false,
  });

  /// Ephemeral user restore intent; never persisted or imported/replayed.
  final bool recreateNewFile;
  final String id;
  final String roundId;
  final Map<String, dynamic>? artifactManifest;
  final String conversationId;
  final String assistantId;
  final bool beforeKnown;
  final String target;
  final String scope;
  final String path;
  final String? before;
  final String? after;
  final bool textSnapshot;
  final bool deleted;
  final String? beforeHash;
  final String afterHash;
  final DateTime updatedAt;
  final bool reverted;

  /// Explicitly registered final artifact, bound to the validated file version.
  /// Missing on old snapshots: a file edit alone is never a final delivery.
  final String? deliveryHash;
  bool get isDelivery => !reverted && deliveryHash == afterHash;

  bool get isNew => textSnapshot && !deleted && beforeKnown && before == null;
  bool get canRestore =>
      textSnapshot && !deleted && beforeKnown && !reverted && before != after;

  String get targetLabel {
    if (!target.startsWith('{')) return target;
    try {
      final data = jsonDecode(target) as Map;
      final location =
          data['root'] ?? data['workspaceId'] ?? data['profileId'] ?? '';
      return '${data['kind'] == 'ssh' ? 'SSH' : '本机'} · $location';
    } on FormatException {
      return target;
    }
  }

  WorkFileChange requestNewFileRecreation() => WorkFileChange(
    id: id,
    conversationId: conversationId,
    assistantId: assistantId,
    target: target,
    scope: scope,
    path: path,
    before: before,
    after: after,
    textSnapshot: textSnapshot,
    deleted: deleted,
    beforeHash: beforeHash,
    afterHash: afterHash,
    updatedAt: updatedAt,
    reverted: reverted,
    beforeKnown: beforeKnown,
    roundId: roundId,
    artifactManifest: artifactManifest,
    recreateNewFile: true,
  );

  WorkFileChange withReverted() => WorkFileChange(
    id: id,
    roundId: roundId,
    artifactManifest: artifactManifest,
    conversationId: conversationId,
    assistantId: assistantId,
    beforeKnown: beforeKnown,
    target: target,
    scope: scope,
    path: path,
    before: before,
    after: after,
    textSnapshot: textSnapshot,
    deleted: deleted,
    beforeHash: beforeHash,
    afterHash: afterHash,
    updatedAt: updatedAt,
    reverted: true,
  );

  WorkFileChange withDelivery(bool selected) => WorkFileChange(
    id: id,
    roundId: roundId,
    artifactManifest: artifactManifest,
    conversationId: conversationId,
    assistantId: assistantId,
    beforeKnown: beforeKnown,
    target: target,
    scope: scope,
    path: path,
    before: before,
    after: after,
    textSnapshot: textSnapshot,
    deleted: deleted,
    beforeHash: beforeHash,
    afterHash: afterHash,
    updatedAt: updatedAt,
    reverted: reverted,
    deliveryHash: selected && !reverted ? afterHash : null,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'roundId': roundId,
    if (artifactManifest != null) 'artifactManifest': artifactManifest,
    'conversationId': conversationId,
    'assistantId': assistantId,
    'beforeKnown': beforeKnown,
    'target': target,
    'scope': scope,
    'path': path,
    'before': before,
    'after': after,
    'textSnapshot': textSnapshot,
    'deleted': deleted,
    'beforeHash': beforeHash,
    'afterHash': afterHash,
    'updatedAt': updatedAt.toIso8601String(),
    'reverted': reverted,
    if (deliveryHash != null) 'deliveryHash': deliveryHash,
  };

  factory WorkFileChange.fromJson(Map<String, dynamic> json) => WorkFileChange(
    id: json['id'] as String,
    roundId: json['roundId'] as String? ?? '',
    artifactManifest: json['artifactManifest'] is Map
        ? Map<String, dynamic>.from(json['artifactManifest'] as Map)
        : null,
    conversationId: json['conversationId'] as String,
    assistantId: json['assistantId'] as String? ?? '',
    beforeKnown: json['beforeKnown'] as bool? ?? true,
    target: json['target'] as String,
    scope: json['scope'] as String,
    path: json['path'] as String,
    before: json['before'] as String?,
    after: json['after'] as String?,
    textSnapshot: json['textSnapshot'] != false,
    deleted: json['deleted'] == true,
    beforeHash: json['beforeHash'] as String?,
    afterHash: json['afterHash'] as String,
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    reverted: json['reverted'] as bool? ?? false,
    deliveryHash: json['deliveryHash'] as String?,
  );
}

/// Resolve latest versions before filtering. An edit/revert after publication
/// invalidates the old artifact rather than resurrecting an earlier snapshot.
List<WorkFileChange> finalDeliveryFiles(
  Iterable<WorkFileChange> changes,
  String conversationId,
  String assistantId,
) {
  final latest = <(String, String, String), WorkFileChange>{};
  for (final file in changes) {
    if (file.conversationId == conversationId &&
        file.assistantId == assistantId) {
      latest[(file.target, file.scope, file.path)] = file;
    }
  }
  return latest.values.where((file) => file.isDelivery).toList();
}

/// Must restore [WorkFileChange.before], or delete an originally new file,
/// through ordinary target permissions and exact [WorkFileChange.afterHash]. Throw if the
/// target is unavailable, permission is denied, or the file has changed.
typedef WorkChangeRestore = Future<void> Function(WorkFileChange change);
