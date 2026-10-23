import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';

enum WorkApprovalMode {
  request('请求批准'),
  assisted('帮我批准'),
  full('完全访问');

  const WorkApprovalMode(this.label);
  final String label;
}

class SessionPolicy {
  const SessionPolicy({
    this.archived = false,
    this.network = true,
    this.approval = WorkApprovalMode.request,
    this.reviewerModel = '',
    this.sshProfileId = '',
    this.remoteRoot = '.',
    this.toolRounds = 24,
    this.roundExtension = 12,
    this.roundReviewAhead = 2,
    this.autoExtendRounds = true,
  });
  final bool archived, network;
  final WorkApprovalMode approval;
  final String reviewerModel, sshProfileId, remoteRoot;
  final int toolRounds, roundExtension, roundReviewAhead;
  final bool autoExtendRounds;
  SessionPolicy copyWith({
    bool? archived,
    bool? network,
    WorkApprovalMode? approval,
    String? reviewerModel,
    String? sshProfileId,
    String? remoteRoot,
    int? toolRounds,
    int? roundExtension,
    int? roundReviewAhead,
    bool? autoExtendRounds,
  }) => SessionPolicy(
    archived: archived ?? this.archived,
    network: network ?? this.network,
    approval: approval ?? this.approval,
    reviewerModel: reviewerModel ?? this.reviewerModel,
    sshProfileId: sshProfileId ?? this.sshProfileId,
    remoteRoot: remoteRoot ?? this.remoteRoot,
    toolRounds: toolRounds ?? this.toolRounds,
    roundExtension: roundExtension ?? this.roundExtension,
    roundReviewAhead: roundReviewAhead ?? this.roundReviewAhead,
    autoExtendRounds: autoExtendRounds ?? this.autoExtendRounds,
  );
  Map<String, dynamic> toJson() => {
    'archived': archived,
    'network': network,
    'approval': approval.name,
    'reviewerModel': reviewerModel,
    'sshProfileId': sshProfileId,
    'remoteRoot': remoteRoot,
    'toolRounds': toolRounds,
    'roundExtension': roundExtension,
    'roundReviewAhead': roundReviewAhead,
    'autoExtendRounds': autoExtendRounds,
  };
  factory SessionPolicy.fromJson(Map<String, dynamic> j) => SessionPolicy(
    archived: j['archived'] == true,
    network: j['network'] != false,
    approval:
        WorkApprovalMode.values
            .where((m) => m.name == j['approval'])
            .firstOrNull ??
        WorkApprovalMode.request,
    reviewerModel: j['reviewerModel'] as String? ?? '',
    sshProfileId: j['sshProfileId'] as String? ?? '',
    remoteRoot: j['remoteRoot'] as String? ?? '.',
    toolRounds: ((j['toolRounds'] as num?)?.toInt() ?? 24).clamp(1, 1000),
    roundExtension: ((j['roundExtension'] as num?)?.toInt() ?? 12).clamp(
      1,
      1000,
    ),
    roundReviewAhead: ((j['roundReviewAhead'] as num?)?.toInt() ?? 2).clamp(
      1,
      1000,
    ),
    autoExtendRounds: j['autoExtendRounds'] != false,
  );
}

final sessionPolicyProvider =
    NotifierProvider<SessionPolicies, Map<String, SessionPolicy>>(
      SessionPolicies.new,
    );

class SessionPolicies extends Notifier<Map<String, SessionPolicy>> {
  Future<void> _pending = Future.value();
  @override
  Map<String, SessionPolicy> build() {
    final raw = ref.read(sharedPrefsProvider).getString('sessionPolicies');
    if (raw == null) return {};
    final values = jsonDecode(raw) as Map;
    return {
      for (final e in values.entries)
        e.key as String: SessionPolicy.fromJson(
          Map<String, dynamic>.from(e.value as Map),
        ),
    };
  }

  Future<void> save(String id, SessionPolicy policy) => saveMany({id: policy});
  Future<void> saveMany(Map<String, SessionPolicy> updates) {
    final prefs = ref.read(sharedPrefsProvider);
    final save = _pending.then((_) async {
      final next = {...state, ...updates};
      if (!await prefs.setString(
        'sessionPolicies',
        jsonEncode(next.map((k, v) => MapEntry(k, v.toJson()))),
      )) {
        throw StateError('会话设置未保存');
      }
      if (ref.mounted) state = next;
    });
    _pending = save.catchError((Object _) {});
    return save;
  }
}
