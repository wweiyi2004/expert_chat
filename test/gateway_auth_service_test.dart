import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/gateway/gateway_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AuthService login uses discovery, state and PKCE', () async {
    final adapter = _OidcAdapter();
    String? authorizationUrl;
    final service = GatewayAuthService(
      dio: Dio()..httpClientAdapter = adapter,
      browser:
          ({required url, required callbackUrlScheme, required options}) async {
            authorizationUrl = url;
            final state = Uri.parse(url).queryParameters['state'];
            expect(callbackUrlScheme, 'expertchat');
            expect(options.useWebview, isTrue);
            return 'expertchat://auth/callback?code=authorization-code&state=$state';
          },
    );
    const config = GatewayConfig(
      authServiceUrl: 'http://localhost:8080/',
      oidcClientId: 'expert-chat',
      oidcRedirectUri: 'expertchat://auth/callback',
    );

    final session = await service.signIn(config);

    final authorize = Uri.parse(authorizationUrl!);
    expect(authorize.path, '/connect/authorize');
    expect(authorize.queryParameters['code_challenge_method'], 'S256');
    expect(authorize.queryParameters['code_challenge'], hasLength(43));
    expect(authorize.queryParameters['scope'], contains('offline_access'));
    expect(adapter.tokenFields?['grant_type'], 'authorization_code');
    expect(adapter.tokenFields?['code_verifier'], isNotEmpty);
    expect(session.subject, 'user-123');
    expect(session.displayName, '测试用户');
    expect(session.refreshToken, 'refresh-1');
  });

  test('refresh preserves a rotated-or-omitted refresh token', () async {
    final adapter = _OidcAdapter(omitRefreshToken: true);
    final service = GatewayAuthService(dio: Dio()..httpClientAdapter = adapter);
    final current = GatewayAuthSession(
      accessToken: _jwt({'sub': 'user-123'}),
      refreshToken: 'keep-me',
      expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      subject: 'user-123',
      displayName: '测试用户',
    );

    final refreshed = await service.refresh(
      const GatewayConfig(authServiceUrl: 'http://localhost:8080'),
      current,
    );

    expect(adapter.tokenFields?['grant_type'], 'refresh_token');
    expect(adapter.tokenFields?['refresh_token'], 'keep-me');
    expect(refreshed.refreshToken, 'keep-me');
    expect(refreshed.subject, 'user-123');
  });
}

String _jwt(Map<String, Object> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part(claims)}.signature';
}

class _OidcAdapter implements HttpClientAdapter {
  _OidcAdapter({this.omitRefreshToken = false});

  final bool omitRefreshToken;
  Map<String, dynamic>? tokenFields;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/.well-known/openid-configuration') {
      return _json({
        'issuer': 'http://localhost:8080/',
        'authorization_endpoint': 'http://localhost:8080/connect/authorize',
        'token_endpoint': 'http://localhost:8080/connect/token',
      });
    }
    if (options.uri.path == '/connect/token') {
      tokenFields = Map<String, dynamic>.from(options.data as Map);
      return _json({
        'access_token': _jwt({
          'sub': 'user-123',
          'preferred_username': '测试用户',
          'exp':
              DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
        }),
        if (!omitRefreshToken) 'refresh_token': 'refresh-1',
        'expires_in': 3600,
      });
    }
    return ResponseBody.fromString('not found', 404);
  }

  ResponseBody _json(Map<String, Object> value) => ResponseBody.fromString(
    jsonEncode(value),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}
