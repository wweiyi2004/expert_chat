import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart';
import 'package:expert_chat/domain/llm/llm_http_errors.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/domain/llm/responses_api_provider.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = LlmConfig(
  baseUrl: 'https://example.invalid/v1',
  apiKey: 'synthetic-test-key',
  model: 'test-model',
);

DioException _failure({
  int? status,
  Object? data,
  DioExceptionType type = DioExceptionType.badResponse,
}) {
  final request = RequestOptions(path: 'https://example.invalid/v1');
  return DioException(
    requestOptions: request,
    type: type,
    response: status == null
        ? null
        : Response<Object?>(
            requestOptions: request,
            statusCode: status,
            data: data,
          ),
  );
}

void main() {
  for (final (name, create) in <(String, LlmProvider Function(Dio))>[
    ('chat', (dio) => OpenAiCompatibleProvider(dio: dio)),
    ('responses', (dio) => ResponsesApiProvider(dio: dio)),
  ]) {
    for (final (status, expected) in [
      (400, '请求参数有误（400）：synthetic detail'),
      (401, 'API Key 无效、已过期或已撤销（401）：请在 /login 管理此来源并更新 Key。'),
      (402, '账户余额或付费额度不足：请核对官方账单及套餐状态。：synthetic detail'),
      (
        404,
        name == 'chat'
            ? '接口未找到（404）：请检查 Base URL 或模型名是否正确。：synthetic detail'
            : '接口未找到（404）：当前 Base URL 可能不支持 Responses API（/responses）。：synthetic detail',
      ),
      (422, '请求参数有误（422）：synthetic detail'),
      (
        429,
        '服务限流（429）：请降低并发并稍后重试；若持续发生，请查看该账号的套餐额度。：synthetic detail',
      ),
      (500, '请求失败（500）：synthetic detail'),
    ]) {
      test('$name preserves user-facing HTTP $status errors', () async {
        final dio = Dio()..httpClientAdapter = _ErrorAdapter(status);
        addTearDown(() => dio.close(force: true));
        await expectLater(
          create(dio).streamChat(config: _config, messages: const []).toList(),
          throwsA(
            predicate((error) => error.toString() == 'Exception: $expected'),
          ),
        );
      });
    }
  }

  test(
    'oversized error streams stop before consuming further chunks',
    () async {
      var consumed = 0;
      Stream<Uint8List> body() async* {
        consumed++;
        yield Uint8List.fromList(List.filled(70 * 1024, 120));
        consumed++;
        throw StateError('The error reader exceeded its byte budget.');
      }

      final error = await humanizeLlmHttpError(
        _failure(status: 500, data: ResponseBody(body(), 500)),
      );
      expect(consumed, 1);
      expect(error.toString(), 'Exception: 请求失败（500）：${'x' * 200}…');
    },
  );

  test('a broken error stream preserves the original HTTP status', () async {
    final error = await humanizeLlmHttpError(
      _failure(
        status: 500,
        data: ResponseBody(
          Stream<Uint8List>.error(StateError('synthetic')),
          500,
        ),
      ),
    );
    expect(error.toString(), 'Exception: 请求失败（500）');
  });

  test(
    'provider messages accept map, JSON text and plain text bodies',
    () async {
      for (final data in <Object>[
        {
          'error': {'message': ' detail '},
        },
        jsonEncode({
          'error': {'message': ' detail '},
        }),
        {'message': ' detail '},
        {'error': ' detail '},
        ' detail ',
      ]) {
        final error = await humanizeLlmHttpError(
          _failure(status: 400, data: data),
        );
        expect(error.toString(), 'Exception: 请求参数有误（400）：detail');
      }
    },
  );

  test('network errors retain their diagnostic category', () async {
    for (final (type, expected) in [
      (DioExceptionType.connectionTimeout, '连接超时'),
      (DioExceptionType.receiveTimeout, '响应超时'),
      (DioExceptionType.sendTimeout, '请求发送超时'),
      (DioExceptionType.connectionError, '连接失败'),
      (DioExceptionType.badCertificate, 'TLS 证书校验失败'),
      (DioExceptionType.unknown, '请求处理异常'),
    ]) {
      final error = await humanizeLlmHttpError(_failure(type: type));
      expect(error.toString(), startsWith('Exception: $expected：'));
    }
  });

  test(
    'socket errors retain safe OS diagnostics; generic exceptions do not leak body data',
    () async {
      final request = RequestOptions(
        path: 'https://example.invalid/v1?api_key=secret',
        headers: {'Authorization': 'Bearer private-key'},
      );
      final socket =
          await humanizeLlmHttpError(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.unknown,
                  error: const SocketException(
                    'connection reset',
                    osError: OSError('reset by peer', 10054),
                  ),
                ),
              )
              as LlmHttpException;
      expect(socket.message, startsWith('网络连接中断'));
      expect(socket.diagnostic, contains('10054'));
      expect(socket.diagnostic, contains('example.invalid'));
      expect(socket.diagnostic, isNot(contains('secret')));
      expect(socket.diagnostic, isNot(contains('private-key')));
      final parse =
          await humanizeLlmHttpError(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.unknown,
                  error: const FormatException('private response body'),
                ),
              )
              as LlmHttpException;
      expect(parse.message, startsWith('请求处理异常'));
      expect(parse.diagnostic, contains('FormatException'));
      expect(parse.toString(), isNot(contains('private response body')));
    },
  );

  test('message clipping preserves complete grapheme clusters', () {
    final emoji = List.filled(201, '👩‍💻').join();
    final clipped = clipLlmErrorMessage(' $emoji ');
    expect(clipped, '${List.filled(200, '👩‍💻').join()}…');
    expect(clipped.characters.length, 201);
  });
}

class _ErrorAdapter implements HttpClientAdapter {
  _ErrorAdapter(this.status);
  final int status;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({
      'error': {'message': 'synthetic detail'},
    }),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}
