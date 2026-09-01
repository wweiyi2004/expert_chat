import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/domain/llm/deepseek_balance_client.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GET /user/balance parses CNY wallet', () async {
    final adapter = _BalanceAdapter(
      jsonEncode({
        'is_available': true,
        'balance_infos': [
          {
            'currency': 'CNY',
            'total_balance': '110.00',
            'granted_balance': '10.00',
            'topped_up_balance': '100.00',
          },
        ],
      }),
    );
    final client = DeepSeekBalanceClient(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final balance = await client.fetch(
      config: const LlmConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-v4-flash',
      ),
    );

    expect(adapter.path, '/user/balance');
    expect(adapter.method, 'GET');
    expect(adapter.authorization, 'Bearer sk-test');
    expect(balance.isAvailable, isTrue);
    expect(balance.infos, hasLength(1));
    expect(balance.infos.single.currency, 'CNY');
    expect(balance.infos.single.totalBalance, '110.00');
    expect(balance.infos.single.grantedBalance, '10.00');
    expect(balance.infos.single.toppedUpBalance, '100.00');
    expect(balance.infos.single.format('110.00'), '¥110.00');
  });

  test('strips /v1 from chat base URL', () async {
    final adapter = _BalanceAdapter(
      jsonEncode({'is_available': true, 'balance_infos': []}),
    );
    final client = DeepSeekBalanceClient(
      dio: Dio()..httpClientAdapter = adapter,
    );

    await client.fetch(
      config: const LlmConfig(
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-test',
        model: 'deepseek-v4-pro',
      ),
    );

    expect(adapter.uri.toString(), 'https://api.deepseek.com/user/balance');
  });

  test('rejects non-DeepSeek hosts', () async {
    final client = DeepSeekBalanceClient(dio: Dio());
    expect(
      () => client.fetch(
        config: const LlmConfig(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk-test',
          model: 'gpt-4o',
        ),
      ),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('不是官方 DeepSeek'),
        ),
      ),
    );
  });

  test('maps 401 to a Chinese auth error', () async {
    final adapter = _BalanceAdapter(
      '{"error":{"message":"invalid"}}',
      status: 401,
    );
    final client = DeepSeekBalanceClient(
      dio: Dio()..httpClientAdapter = adapter,
    );

    expect(
      () => client.fetch(
        config: const LlmConfig(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'bad',
          model: 'deepseek-v4-flash',
        ),
      ),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('鉴权失败'),
        ),
      ),
    );
  });
}

class _BalanceAdapter implements HttpClientAdapter {
  _BalanceAdapter(this.body, {this.status = 200});

  final String body;
  final int status;
  String method = '';
  String path = '';
  String authorization = '';
  Uri uri = Uri();

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    method = options.method;
    path = options.uri.path;
    uri = options.uri;
    authorization = options.headers['Authorization']?.toString() ?? '';
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}
