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
  });

  final String id;
  final String conversationId;
  final String assistantId;
  final bool beforeKnown;
  final String target;
  final String scope;
  final String path;
  final String? before;
  final String after;
  final String? beforeHash;
  final String afterHash;
  final DateTime updatedAt;
  final bool reverted;

  /// Explicitly registered final artifact, bound to the validated file version.
  /// Missing on old snapshots: a file edit alone is never a final delivery.
  final String? deliveryHash;
  bool get isDelivery => !reverted && deliveryHash == afterHash;

  bool get isNew => beforeKnown && before == null;
  bool get canRestore => beforeKnown && !isNew && !reverted && before != after;

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

  WorkFileChange withReverted() => WorkFileChange(
    id: id,
    conversationId: conversationId,
    assistantId: assistantId,
    beforeKnown: beforeKnown,
    target: target,
    scope: scope,
    path: path,
    before: before,
    after: after,
    beforeHash: beforeHash,
    afterHash: afterHash,
    updatedAt: updatedAt,
    reverted: true,
  );

  WorkFileChange withDelivery(bool selected) => WorkFileChange(
    id: id,
    conversationId: conversationId,
    assistantId: assistantId,
    beforeKnown: beforeKnown,
    target: target,
    scope: scope,
    path: path,
    before: before,
    after: after,
    beforeHash: beforeHash,
    afterHash: afterHash,
    updatedAt: updatedAt,
    reverted: reverted,
    deliveryHash: selected && !reverted ? afterHash : null,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'assistantId': assistantId,
    'beforeKnown': beforeKnown,
    'target': target,
    'scope': scope,
    'path': path,
    'before': before,
    'after': after,
    'beforeHash': beforeHash,
    'afterHash': afterHash,
    'updatedAt': updatedAt.toIso8601String(),
    'reverted': reverted,
    if (deliveryHash != null) 'deliveryHash': deliveryHash,
  };

  factory WorkFileChange.fromJson(Map<String, dynamic> json) => WorkFileChange(
    id: json['id'] as String,
    conversationId: json['conversationId'] as String,
    assistantId: json['assistantId'] as String? ?? '',
    beforeKnown: json['beforeKnown'] as bool? ?? true,
    target: json['target'] as String,
    scope: json['scope'] as String,
    path: json['path'] as String,
    before: json['before'] as String?,
    after: json['after'] as String,
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

/// Must write [WorkFileChange.before] through the target's ordinary permission
/// checks, supplying [WorkFileChange.afterHash] as expected_sha256. Throw if the
/// target is unavailable, permission is denied, or the file has changed.
typedef WorkChangeRestore = Future<void> Function(WorkFileChange change);
