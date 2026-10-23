import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/auth/chatgpt_network_io.dart';
import 'package:expert_chat/domain/llm/auth/chatgpt_auth_errors.dart';
import 'package:dio/dio.dart';

void main() {
  test('Windows browser proxy is normalized for HTTPS CONNECT', () {
    expect(proxyDirective('127.0.0.1:7890'), 'PROXY 127.0.0.1:7890');
    expect(
      proxyDirective('http=127.0.0.1:8080;https=127.0.0.1:7890'),
      'PROXY 127.0.0.1:7890',
    );
    expect(proxyDirective('http://127.0.0.1:7890'), 'PROXY 127.0.0.1:7890');
    expect(proxyDirective(''), 'DIRECT');
    expect(proxyDirective('http://name:secret@host:1234'), 'DIRECT');
  });
  test(
    'login errors describe the stage without exposing request credentials',
    () {
      final options = RequestOptions(
        path: '/oauth/token',
        headers: {'Authorization': 'secret'},
      );
      final error = DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 403),
      );
      final text = describeChatGptAuthFailure(error);
      expect(text, contains('403'));
      expect(text, isNot(contains('secret')));
    },
  );
}
