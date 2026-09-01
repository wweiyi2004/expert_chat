import 'package:dio/dio.dart';

import 'llm_provider.dart';

/// One currency wallet from DeepSeek `GET /user/balance`.
class DeepSeekBalanceInfo {
  const DeepSeekBalanceInfo({
    required this.currency,
    required this.totalBalance,
    required this.grantedBalance,
    required this.toppedUpBalance,
  });

  /// `CNY` or `USD`.
  final String currency;
  final String totalBalance;
  final String grantedBalance;
  final String toppedUpBalance;

  String get symbol => switch (currency.toUpperCase()) {
    'CNY' => '¥',
    'USD' => r'$',
    _ => '',
  };

  String get currencyLabel => switch (currency.toUpperCase()) {
    'CNY' => '人民币',
    'USD' => '美元',
    _ => currency,
  };

  String format(String amount) => '$symbol$amount';
}

/// Official DeepSeek account balance.
///
/// See https://api-docs.deepseek.com/api/get-user-balance
class DeepSeekBalance {
  const DeepSeekBalance({required this.isAvailable, required this.infos});

  /// Whether the account can still make API calls.
  final bool isAvailable;
  final List<DeepSeekBalanceInfo> infos;

  factory DeepSeekBalance.fromJson(Map<String, dynamic> json) {
    final raw = json['balance_infos'];
    final infos = <DeepSeekBalanceInfo>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        infos.add(
          DeepSeekBalanceInfo(
            currency: '${item['currency'] ?? ''}',
            totalBalance: '${item['total_balance'] ?? '0'}',
            grantedBalance: '${item['granted_balance'] ?? '0'}',
            toppedUpBalance: '${item['topped_up_balance'] ?? '0'}',
          ),
        );
      }
    }
    return DeepSeekBalance(
      isAvailable: json['is_available'] == true,
      infos: infos,
    );
  }
}

/// Fetches the signed-in DeepSeek account balance. Only the official host
/// (`api.deepseek.com`) exposes this endpoint; aggregators do not.
class DeepSeekBalanceClient {
  DeepSeekBalanceClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
            ),
          );

  final Dio _dio;

  Future<DeepSeekBalance> fetch({
    required LlmConfig config,
    CancelToken? cancelToken,
  }) async {
    if (!config.isOfficialDeepSeek) {
      throw Exception('当前服务商不是官方 DeepSeek，无法查询账户余额。');
    }
    if (config.apiKey.trim().isEmpty) {
      throw Exception('请先填写 DeepSeek API Key。');
    }
    final url = _balanceUrl(config.baseUrl);
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Accept': 'application/json',
          },
          responseType: ResponseType.json,
        ),
      );
      final data = response.data;
      if (data == null) {
        throw Exception('余额接口返回为空。');
      }
      return DeepSeekBalance.fromJson(data);
    } on DioException catch (e) {
      throw await _humanizeError(e);
    }
  }

  /// Always hit `{origin}/user/balance`, even if the chat base URL includes
  /// `/v1` (OpenAI-style).
  static String _balanceUrl(String baseUrl) {
    final parsed = Uri.parse(baseUrl.trim());
    return Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: '/user/balance',
    ).toString();
  }

  Future<Exception> _humanizeError(DioException e) async {
    final status = e.response?.statusCode;
    if (status == 401) {
      return Exception('鉴权失败（401）：请检查 API Key 是否正确。');
    }
    if (status == 402) {
      return Exception('额度不足（402）：账户余额不足。');
    }
    if (status == 404) {
      return Exception('余额接口未找到（404）：请确认使用的是官方 DeepSeek 地址。');
    }
    if (status == 429) {
      return Exception('请求过于频繁（429）：稍后重试。');
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return Exception('查询余额超时：请检查网络后重试。');
    }
    if (e.type == DioExceptionType.connectionError) {
      return Exception('连接失败：请检查网络。');
    }
    if (e.type == DioExceptionType.cancel) {
      return Exception('已取消');
    }
    return Exception('查询余额失败${status == null ? '' : '（$status）'}。');
  }
}
