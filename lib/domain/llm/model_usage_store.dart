import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'llm_provider.dart';

const _modelUsageStorageKey = 'modelUsage.v1';

class ModelUsageRecord {
  const ModelUsageRecord({
    required this.endpoint,
    required this.model,
    this.requests = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.reasoningTokens = 0,
    this.lastUsedAt,
  });

  final String endpoint;
  final String model;
  final int requests;
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int reasoningTokens;
  final DateTime? lastUsedAt;

  int get totalTokens => inputTokens + outputTokens;

  double get cacheHitRate =>
      inputTokens <= 0 ? 0 : cachedInputTokens / inputTokens;

  String get key => ModelUsageStore.keyFor(endpoint, model);

  ModelUsageRecord copyWith({
    int? requests,
    int? inputTokens,
    int? outputTokens,
    int? cachedInputTokens,
    int? reasoningTokens,
    DateTime? lastUsedAt,
  }) => ModelUsageRecord(
    endpoint: endpoint,
    model: model,
    requests: requests ?? this.requests,
    inputTokens: inputTokens ?? this.inputTokens,
    outputTokens: outputTokens ?? this.outputTokens,
    cachedInputTokens: cachedInputTokens ?? this.cachedInputTokens,
    reasoningTokens: reasoningTokens ?? this.reasoningTokens,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
  );

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'model': model,
    'requests': requests,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'cachedInputTokens': cachedInputTokens,
    'reasoningTokens': reasoningTokens,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
  };

  static ModelUsageRecord? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final endpoint = raw['endpoint']?.toString().trim() ?? '';
    final model = raw['model']?.toString().trim() ?? '';
    if (endpoint.isEmpty || model.isEmpty) return null;
    return ModelUsageRecord(
      endpoint: endpoint,
      model: model,
      requests: _readInt(raw['requests']),
      inputTokens: _readInt(raw['inputTokens']),
      outputTokens: _readInt(raw['outputTokens']),
      cachedInputTokens: _readInt(raw['cachedInputTokens']),
      reasoningTokens: _readInt(raw['reasoningTokens']),
      lastUsedAt: DateTime.tryParse(raw['lastUsedAt']?.toString() ?? ''),
    );
  }

  static int _readInt(dynamic value) =>
      (value is num ? value.toInt() : int.tryParse(value?.toString() ?? ''))
          ?.clamp(0, 1 << 31)
          .toInt() ??
      0;
}

/// Local, device-only usage ledger for model requests.
///
/// The ledger intentionally stores endpoint + model rather than API keys or
/// request bodies. It is therefore useful for diagnostics without persisting
/// secrets or conversation content.
class ModelUsageStore {
  ModelUsageStore(this._prefs) {
    _load();
  }

  final SharedPreferences _prefs;
  final Map<String, ModelUsageRecord> _records = {};
  Future<void> _writeQueue = Future<void>.value();

  List<ModelUsageRecord> get records => List.unmodifiable(
    _records.values.toList()..sort((a, b) {
      final byEndpoint = a.endpoint.compareTo(b.endpoint);
      return byEndpoint != 0 ? byEndpoint : a.model.compareTo(b.model);
    }),
  );

  static String keyFor(String endpoint, String model) =>
      '${_normalizeEndpoint(endpoint)}\u0000${model.trim()}';

  ModelUsageRecord? find({required String endpoint, required String model}) =>
      _records[keyFor(endpoint, model)];

  List<ModelUsageRecord> forEndpoint(String endpoint) {
    final normalized = _normalizeEndpoint(endpoint);
    return records
        .where((r) => _normalizeEndpoint(r.endpoint) == normalized)
        .toList();
  }

  ModelUsageRecord totals({String? endpoint}) {
    final source = endpoint == null ? records : forEndpoint(endpoint);
    return ModelUsageRecord(
      endpoint: endpoint?.trim() ?? '全部服务商',
      model: '全部模型',
      requests: source.fold(0, (sum, r) => sum + r.requests),
      inputTokens: source.fold(0, (sum, r) => sum + r.inputTokens),
      outputTokens: source.fold(0, (sum, r) => sum + r.outputTokens),
      cachedInputTokens: source.fold(0, (sum, r) => sum + r.cachedInputTokens),
      reasoningTokens: source.fold(0, (sum, r) => sum + r.reasoningTokens),
    );
  }

  void record({
    required String endpoint,
    required String model,
    required LlmUsage usage,
  }) {
    if (!usage.hasValues) return;
    final trimmedEndpoint = endpoint.trim();
    final trimmedModel = model.trim();
    if (trimmedEndpoint.isEmpty || trimmedModel.isEmpty) return;
    final key = keyFor(trimmedEndpoint, trimmedModel);
    final previous = _records[key];
    final now = DateTime.now();
    _records[key] = ModelUsageRecord(
      endpoint: previous?.endpoint ?? trimmedEndpoint,
      model: previous?.model ?? trimmedModel,
      requests: (previous?.requests ?? 0) + 1,
      inputTokens: (previous?.inputTokens ?? 0) + usage.inputTokens,
      outputTokens: (previous?.outputTokens ?? 0) + usage.outputTokens,
      cachedInputTokens:
          (previous?.cachedInputTokens ?? 0) + usage.cachedInputTokens,
      reasoningTokens: (previous?.reasoningTokens ?? 0) + usage.reasoningTokens,
      lastUsedAt: now,
    );
    _enqueueWrite();
  }

  Future<void> clear({String? endpoint}) async {
    if (endpoint == null) {
      _records.clear();
    } else {
      final normalized = _normalizeEndpoint(endpoint);
      _records.removeWhere(
        (_, record) => _normalizeEndpoint(record.endpoint) == normalized,
      );
    }
    await _enqueueWrite();
  }

  Future<void> flush() => _writeQueue;

  void _load() {
    final raw = _prefs.getString(_modelUsageStorageKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        final record = ModelUsageRecord.fromJson(item);
        if (record != null) _records[record.key] = record;
      }
    } catch (_) {
      // A damaged usage ledger is disposable; it must never block settings.
    }
  }

  Future<void> _enqueueWrite() {
    final encoded = jsonEncode(_records.values.map((r) => r.toJson()).toList());
    _writeQueue = _writeQueue.then(
      (_) => _prefs.setString(_modelUsageStorageKey, encoded),
    );
    return _writeQueue;
  }

  static String _normalizeEndpoint(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '').toLowerCase();
}
