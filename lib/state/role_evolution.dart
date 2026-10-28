import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/providers.dart';
import '../data/subagent_role.dart';

class RoleCandidate {
  const RoleCandidate({
    required this.role,
    required this.version,
    required this.source,
    required this.requiredTools,
    this.evidence = const [],
    this.history = const [],
    this.disabled = false,
  });
  final SubagentRole role;
  final int version;
  final String source;
  final List<String> requiredTools;
  final List<Map<String, dynamic>> evidence, history;
  final bool disabled;
  bool get verified => evidence.any(
    (e) =>
        e['version'] == version &&
        e['success'] == true &&
        (e['acceptance'] as String? ?? '').trim().isNotEmpty &&
        ((e['artifacts'] as Map?)?.isNotEmpty == true ||
            (e['resultHash'] as String? ?? '').isNotEmpty),
  );
  Map<String, dynamic> toJson() => {
    'role': role.toJson(),
    'version': version,
    'source': source,
    'requiredTools': requiredTools,
    'evidence': evidence,
    'history': history,
    'disabled': disabled,
  };
  factory RoleCandidate.fromJson(Map<String, dynamic> value) => RoleCandidate(
    role: SubagentRole.fromJson(
      Map<String, dynamic>.from(value['role'] as Map),
    ),
    version: value['version'] as int,
    source: value['source'] as String,
    requiredTools: (value['requiredTools'] as List).cast<String>(),
    evidence: (value['evidence'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList(),
    history: (value['history'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList(),
    disabled: value['disabled'] == true,
  );
}

final roleEvolutionProvider =
    NotifierProvider<RoleEvolutionController, List<RoleCandidate>>(
      RoleEvolutionController.new,
    );

class RoleEvolutionController extends Notifier<List<RoleCandidate>> {
  static const storageKey = 'roleEvolution.v1';
  final _searches = <String, Set<String>>{};
  Future<void> _pending = Future.value();
  @override
  List<RoleCandidate> build() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(storageKey);
      return raw == null
          ? []
          : (jsonDecode(raw) as List)
                .map(
                  (v) => RoleCandidate.fromJson(
                    Map<String, dynamic>.from(v as Map),
                  ),
                )
                .take(40)
                .toList();
    } catch (_) {
      return [];
    }
  }

  Map<String, dynamic> search({
    required String task,
    required List<SubagentRole> roles,
    required List<String> availableTools,
    List<String> materials = const [],
  }) {
    final words = task
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    int score(SubagentRole role) => words
        .where(
          (w) => '${role.name} ${role.when} ${role.instructions}'
              .toLowerCase()
              .contains(w),
        )
        .length;
    final matches = [...roles]..sort((a, b) => score(b).compareTo(score(a)));
    final id = const Uuid().v4();
    _searches[id] = availableTools.toSet();
    if (_searches.length > 32) _searches.remove(_searches.keys.first);
    return {
      'search_id': id,
      'roles': matches
          .take(10)
          .map(
            (r) => {
              'id': r.id,
              'name': r.name,
              'when': r.when,
              'enabled': r.enabled,
            },
          )
          .toList(),
      'tools': availableTools,
      'materials': materials.take(20).toList(),
      'rule':
          'Reuse an existing suitable role first. A prompt cannot grant unavailable tools or permissions.',
    };
  }

  Future<RoleCandidate> propose({
    required String searchId,
    required String name,
    required String when,
    required String instructions,
    required String model,
    required List<String> requiredTools,
    required String source,
  }) async {
    final tools = _searches[searchId];
    if (tools == null) throw StateError('请先检索现有角色、工具与资料');
    if (requiredTools.any((tool) => !tools.contains(tool))) {
      throw StateError('候选角色要求当前不可用工具');
    }
    if (name.trim().isEmpty ||
        when.trim().isEmpty ||
        instructions.trim().isEmpty ||
        instructions.length > 24000 ||
        source.trim().isEmpty ||
        source.length > 2000) {
      throw ArgumentError('角色名称、适用范围、指令与来源不能为空，指令最多 24000 字符');
    }
    final candidate = RoleCandidate(
      role: SubagentRole(
        id: 'evolved-${const Uuid().v4()}',
        name: name,
        when: when,
        instructions: instructions,
        model: model,
        enabled: false,
      ),
      version: 1,
      source: source,
      requiredTools: requiredTools.toSet().toList(),
    );
    await _write((current) {
      if (current.length >= 40) throw StateError('候选库已满，请删除旧候选');
      return [...current, candidate];
    });
    return candidate;
  }

  SubagentRole trialRole(
    String id, {
    required List<String> availableTools,
    required List<String> allowedModels,
  }) {
    final candidate = state.where((c) => c.role.id == id).firstOrNull;
    if (candidate == null || candidate.disabled) {
      throw StateError('候选角色不存在或已禁用');
    }
    if (candidate.requiredTools.any((tool) => !availableTools.contains(tool)) ||
        candidate.role.model.isNotEmpty &&
            !allowedModels.contains(candidate.role.model)) {
      throw StateError('候选角色的工具或模型当前不可用');
    }
    return candidate.role;
  }

  /// Called by the host only, using actual trial completion and artifact hashes.
  /// No model-facing tool can supply this evidence directly.
  Future<void> recordEvidence({
    required String id,
    required int version,
    required String taskId,
    required Map<String, String> artifactVersions,
    required bool success,
    required String summary,
    String resultHash = '',
    String acceptance = '',
  }) => _write(
    (current) => [
      for (final candidate in current)
        if (candidate.role.id == id && candidate.version == version)
          RoleCandidate(
            role: candidate.role,
            version: version,
            source: candidate.source,
            requiredTools: candidate.requiredTools,
            disabled: candidate.disabled,
            history: candidate.history,
            evidence: [
              ...candidate.evidence,
              {
                'version': version,
                'taskId': taskId,
                'artifacts': artifactVersions,
                'success': success,
                'resultHash': resultHash,
                'acceptance': acceptance,
                'summary': summary.length > 1000
                    ? summary.substring(0, 1000)
                    : summary,
                'at': DateTime.now().toUtc().toIso8601String(),
              },
            ].reversed.take(10).toList().reversed.toList(),
          )
        else
          candidate,
    ],
  );
  Future<void> revise(String id, SubagentRole role, {bool? disabled}) => _write(
    (current) => [
      for (final candidate in current)
        if (candidate.role.id == id)
          RoleCandidate(
            role: role.copyWith(enabled: false),
            version: candidate.version + 1,
            source: '${candidate.source}\n用户修订',
            requiredTools: candidate.requiredTools,
            disabled: disabled ?? candidate.disabled,
            evidence: const [],
            history: [
              ...candidate.history,
              candidate.toJson()..remove('history'),
            ].reversed.take(5).toList().reversed.toList(),
          )
        else
          candidate,
    ],
  );
  Future<void> rollback(String id, int version) async {
    final candidate = state.firstWhere((c) => c.role.id == id);
    final previous = candidate.history.firstWhere(
      (entry) => entry['version'] == version,
    );
    await revise(
      id,
      SubagentRole.fromJson(Map<String, dynamic>.from(previous['role'] as Map)),
    );
  }

  /// Human review of an already observed host result. Never exposed as a model
  /// tool; the UI shows the actual trial summary and result/artifact version.
  Future<void> acceptEvidence(
    String id,
    int version,
    String taskId,
    String criteria,
  ) {
    if (criteria.trim().length < 8 || criteria.length > 2000) {
      throw ArgumentError('请填写具体的验收依据（8–2000 字符）');
    }
    return _write(
      (current) => [
        for (final candidate in current)
          if (candidate.role.id == id && candidate.version == version)
            RoleCandidate(
              role: candidate.role,
              version: version,
              source: candidate.source,
              requiredTools: candidate.requiredTools,
              history: candidate.history,
              disabled: candidate.disabled,
              evidence: [
                for (final evidence in candidate.evidence)
                  if (evidence['taskId'] == taskId &&
                      evidence['version'] == version &&
                      evidence['success'] == true &&
                      ((evidence['artifacts'] as Map?)?.isNotEmpty == true ||
                          (evidence['resultHash'] as String? ?? '').isNotEmpty))
                    {
                      ...evidence,
                      'acceptance': criteria.trim(),
                      'acceptedBy': 'user',
                    }
                  else
                    evidence,
              ],
            )
          else
            candidate,
      ],
    );
  }

  Future<void> recordModelReview({
    required String id,
    required int version,
    required String taskId,
    required String resultHash,
    required bool passed,
    required String criteria,
    required String limitations,
    required String model,
    String evidenceHash = '',
  }) => _write(
    (current) => [
      for (final candidate in current)
        if (candidate.role.id == id && candidate.version == version)
          RoleCandidate(
            role: candidate.role,
            version: version,
            source: candidate.source,
            requiredTools: candidate.requiredTools,
            history: candidate.history,
            disabled: candidate.disabled,
            evidence: [
              for (final evidence in candidate.evidence)
                if (evidence['taskId'] == taskId &&
                    evidence['version'] == version &&
                    evidence['resultHash'] == resultHash)
                  {
                    ...evidence,
                    'reviewPassed': passed,
                    'reviewModel': model,
                    'reviewEvidenceHash': evidenceHash,
                    'reviewCriteria': criteria,
                    'reviewLimitations': limitations,
                    if (passed && evidence['success'] == true)
                      'acceptance': criteria,
                    if (passed) 'acceptedBy': 'model:$model',
                  }
                else
                  evidence,
            ],
          )
        else
          candidate,
    ],
  );

  Future<void> delete(String id) =>
      _write((current) => current.where((c) => c.role.id != id).toList());
  Future<void> _write(
    List<RoleCandidate> Function(List<RoleCandidate>) update,
  ) {
    final operation = _pending.then((_) async {
      final next = update(state);
      if (!await ref
          .read(sharedPrefsProvider)
          .setString(
            storageKey,
            jsonEncode(next.map((c) => c.toJson()).toList()),
          )) {
        throw StateError('候选角色保存失败');
      }
      if (ref.mounted) state = next;
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}
