import 'package:dio/dio.dart';
import '../../data/provider_profile.dart';
import 'llm_http_errors.dart';

/// Read-only official quota APIs. No model calls, guessed endpoints or redirects.
/// Sources: MoonshotAI/kimi-code packages/oauth/src/managed-usage.ts;
/// zai-org/zai-coding-plugins usage-query-skill/scripts/query-usage.mjs;
/// MiniMax-AI/cli quota API and https://www.minimax.io/m-plan.
class SubscriptionUsageService {
  final _cache = <String, Map<String, Object?>>{};
  final _pending = <String, Future<Map<String, Object?>>>{};
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 15),
      followRedirects: false,
    ),
  );

  static Uri? endpoint(ProviderProfile p) {
    if (p.authMode == 'chatgpt' || p.authMode == 'none') return null;
    final uri = Uri.tryParse(p.baseUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port != 443) {
      return null;
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if ({'api.kimi.com', 'api.kimi.ai'}.contains(uri.host) &&
        path == '/coding/v1') {
      return uri.replace(path: '/coding/v1/usages');
    }
    if (p.authMode != 'apiKey') return null;
    if ({'open.bigmodel.cn', 'api.z.ai'}.contains(uri.host) &&
        {
          '/api/anthropic',
          '/api/anthropic/v1',
          '/api/coding/paas/v4',
        }.contains(path)) {
      return uri.replace(path: '/api/monitor/usage/quota/limit');
    }
    if ({'api.minimaxi.com', 'api.minimax.io'}.contains(uri.host) &&
        {'/anthropic', '/anthropic/v1', '/v1'}.contains(path)) {
      return uri.replace(path: '/v1/token_plan/remains');
    }
    return null;
  }

  Future<Map<String, Object?>> inspect(
    ProviderProfile profile, {
    required Future<String> Function() credential,
    required Map<String, Object?> metadata,
    Map<String, String> headers = const {},
    bool refresh = false,
  }) async {
    final url = endpoint(profile);
    final key = '${profile.id}\n${profile.baseUrl}\n${profile.authMode}';
    final base = <String, Object?>{
      ...metadata,
      'capability': url == null ? 'unsupported' : 'available',
      'state': 'not_loaded',
      'windows': <Object?>[],
      'notice': url == null
          ? '当前来源没有已接入的官方额度接口；请打开官方控制台查看。'
          : '点击刷新读取官方套餐额度；不会发送模型请求。',
    };
    if (url == null) return base;
    if (!refresh) {
      return _cache[key] == null
          ? base
          : {...base, ..._cache[key]!, 'cached': true};
    }
    final existing = _pending[key];
    if (existing != null) return existing;
    final future = _fetch(profile, url, credential, headers, base);
    _pending[key] = future;
    try {
      final value = await future;
      _cache[key] = value;
      // Keep only the latest endpoint per saved source.
      _cache.removeWhere((k, _) => k.startsWith('${profile.id}\n') && k != key);
      return value;
    } finally {
      if (identical(_pending[key], future)) _pending.remove(key);
    }
  }

  Future<Map<String, Object?>> _fetch(
    ProviderProfile p,
    Uri url,
    Future<String> Function() credential,
    Map<String, String> headers,
    Map<String, Object?> base,
  ) async {
    final checked = DateTime.now().toUtc();
    try {
      final key = await credential();
      if (key.trim().isEmpty) {
        throw StateError('此账号没有可用凭据，请在 /login 更新授权或 Key。');
      }
      final isGlm = url.path.contains('/monitor/');
      final response = await _dio.getUri<Object?>(
        url,
        options: Options(
          headers: {
            ...headers,
            'Authorization': isGlm ? key : 'Bearer $key',
            'Accept': 'application/json',
          },
        ),
      );
      final raw = _map(response.data);
      if (raw.isEmpty) throw StateError('额度接口未返回可识别的数据，请查看官方控制台。');
      final business = _map(raw['base_resp']);
      if (raw['success'] == false ||
          (_number(business['status_code']) ?? 0) != 0) {
        throw StateError('额度接口拒绝查询；请核对套餐 Key、账号权限或在官方控制台查看。');
      }
      final data = raw['data'] is Map ? _map(raw['data']) : raw;
      final windows = <Map<String, Object?>>[];
      if (url.path.endsWith('/usages')) {
        final usages = _map(data['usages']);
        for (final entry in const {
          'limit_5h': '5 小时',
          'limit_7d': '7 天',
          'limit_month_total': '月度总额度',
          'limit_month_code': '月度编程额度',
        }.entries) {
          final item = _map(usages[entry.key]);
          final used = _number(item['used_ratio']);
          if (used != null) {
            windows.add(
              _window(
                entry.value,
                usedPercent: used * 100,
                reset: item['reset_time'],
              ),
            );
          }
        }
        // Older plans still return counters. Keep contradictory reports visible.
        final legacy = _map(data['usage']);
        if (legacy.isNotEmpty) {
          _counterWindow(
            windows,
            windows.isEmpty ? '套餐总额度' : '套餐计数（服务端）',
            legacy,
          );
        }
        for (final item in _list(data['limits'])) {
          final row = _map(item), window = _map(_map(item)['window']);
          final duration = _number(window['duration']);
          _counterWindow(
            windows,
            '窗口计数 ${duration?.toInt() ?? ''} ${_string(window['timeUnit']).replaceFirst('TIME_UNIT_', '')}',
            _map(row['detail']),
          );
        }
      } else if (isGlm) {
        for (final item in _list(data['limits'])) {
          final row = _map(item), type = _string(_map(item)['type']);
          final value = _number(row['percentage']);
          final total = _number(row['usage']),
              used = _number(row['currentValue']);
          final label = switch (type) {
            'TOKENS_LIMIT' => 'Token 额度',
            'TIME_LIMIT' => '工具调用额度',
            'CREDIT_LIMIT' => '套餐积分',
            _ => type.isEmpty ? '套餐额度' : type,
          };
          windows.add(
            _window(
              '$label${row['unit'] == null ? '' : ' · ${row['unit']}'}',
              usedPercent: value,
              total: total,
              used: used,
              reset: row['nextResetTime'] ?? row['resetTime'],
            ),
          );
        }
      } else {
        for (final item in _list(data['model_remains'])) {
          final row = _map(item), name = _string(_map(item)['model_name']);
          for (final weekly in [false, true]) {
            final prefix = weekly ? 'current_weekly' : 'current_interval';
            final remaining = _number(row['${prefix}_remaining_percent']);
            final total = _number(row['${prefix}_total_count']);
            final used = _number(row['${prefix}_usage_count']);
            final ms = _number(
              row[weekly ? 'weekly_remains_time' : 'remains_time'],
            );
            if (remaining == null && (total == null || total <= 0)) continue;
            windows.add(
              _window(
                '$name · ${weekly ? '每周' : '当前窗口'}',
                remainingPercent: remaining,
                total: total != null && total > 0 ? total : null,
                used: total != null && total > 0 ? used : null,
                reset: ms != null && ms >= 0
                    ? checked
                          .add(Duration(milliseconds: ms.toInt()))
                          .toIso8601String()
                    : null,
              ),
            );
          }
        }
      }
      return {
        ...base,
        'capability': windows.isEmpty ? 'error' : 'available',
        'state': windows.isEmpty ? 'error' : 'ready',
        'cached': false,
        'checked_at': checked.toIso8601String(),
        'windows': windows,
        'notice': windows.isEmpty
            ? '接口未报告可识别的额度字段；请打开官方控制台核对。'
            : '数据由官方接口报告；未报告的重置或套餐到期时间保持未知。计数与百分比可能来自不同额度池。',
      };
    } on DioException catch (error) {
      final humanized = await humanizeLlmHttpError(error, authMode: p.authMode);
      return {
        ...base,
        'capability': 'error',
        'state': 'error',
        'checked_at': checked.toIso8601String(),
        'notice': humanized is LlmHttpException
            ? humanized.message
            : '额度读取失败，请稍后重试。',
      };
    } on StateError catch (error) {
      return {
        ...base,
        'capability': 'error',
        'state': 'error',
        'checked_at': checked.toIso8601String(),
        'notice': error.message,
      };
    } catch (_) {
      return {
        ...base,
        'capability': 'error',
        'state': 'error',
        'checked_at': checked.toIso8601String(),
        'notice': '额度读取失败；请重新授权或在官方控制台查看。',
      };
    }
  }

  static Map<String, Object?> _window(
    String label, {
    double? usedPercent,
    double? remainingPercent,
    double? total,
    double? used,
    double? remaining,
    Object? reset,
  }) {
    final pct =
        usedPercent ??
        (remainingPercent == null
            ? total != null && total > 0 && used != null
                  ? used / total * 100
                  : null
            : 100 - remainingPercent);
    return {
      'label': label,
      if (pct != null) 'used_percent': pct.clamp(0, 100),
      if (pct != null) 'remaining_percent': (100 - pct).clamp(0, 100),
      'total': ?total,
      'used': ?used,
      'remaining': ?remaining,
      if (_date(reset) case final String date) 'reset_at': date,
    };
  }

  static void _counterWindow(
    List<Map<String, Object?>> target,
    String name,
    Map<String, dynamic> row,
  ) {
    final total = _number(row['limit']),
        used = _number(row['used']),
        remaining = _number(row['remaining']);
    if (total == null || total <= 0 || (used == null && remaining == null)) {
      return;
    }
    target.add(
      _window(
        name,
        total: total,
        used: used ?? total - remaining!,
        remaining: remaining,
        reset: row['resetTime'] ?? row['reset_time'],
      ),
    );
  }

  static String? _date(Object? value) {
    if (value is num && value.isFinite) {
      return DateTime.fromMillisecondsSinceEpoch(
        (value < 100000000000 ? value * 1000 : value).toInt(),
        isUtc: true,
      ).toIso8601String();
    }
    return value is String
        ? DateTime.tryParse(value)?.toUtc().toIso8601String()
        : null;
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  static List<Object?> _list(Object? value) => value is List ? value : [];
  static String _string(Object? value) => value is String ? value : '';
  static double? _number(Object? value) {
    final n = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    return n != null && n.isFinite ? n : null;
  }
}
