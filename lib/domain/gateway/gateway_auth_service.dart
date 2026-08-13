import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../data/gateway_config.dart';

typedef GatewayAuthBrowser =
    Future<String> Function({
      required String url,
      required String callbackUrlScheme,
      required FlutterWebAuth2Options options,
    });

class GatewayAuthException implements Exception {
  const GatewayAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GatewayAuthSession {
  const GatewayAuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.subject,
    required this.displayName,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String subject;
  final String displayName;

  bool get needsRefresh =>
      DateTime.now().toUtc().add(const Duration(minutes: 2)).isAfter(expiresAt);

  GatewayAuthSession copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) => GatewayAuthSession(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt ?? this.expiresAt,
    subject: subject,
    displayName: displayName,
  );
}

class GatewayAuthService {
  GatewayAuthService({Dio? dio, GatewayAuthBrowser? browser})
    : _dio =
          dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15))),
      _browser = browser ?? FlutterWebAuth2.authenticate;

  final Dio _dio;
  final GatewayAuthBrowser _browser;

  Future<GatewayAuthSession> signIn(GatewayConfig config) async {
    _validateConfig(config);
    final discovery = await _discovery(config);
    final verifier = _randomUrlSafe(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomUrlSafe(32);
    final redirect = Uri.parse(config.oidcRedirectUri.trim());
    final authorize = Uri.parse(discovery.authorizationEndpoint).replace(
      queryParameters: {
        'client_id': config.oidcClientId.trim(),
        'redirect_uri': redirect.toString(),
        'response_type': 'code',
        'scope': 'openid profile email offline_access',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
      },
    );
    late final String callback;
    try {
      callback = await _browser(
        url: authorize.toString(),
        callbackUrlScheme: redirect.scheme,
        options: FlutterWebAuth2Options(
          useWebview: true,
          timeout: 5 * 60,
          httpsHost: redirect.host.isEmpty ? null : redirect.host,
          httpsPath: redirect.path.isEmpty ? '/' : redirect.path,
        ),
      );
    } catch (error) {
      throw GatewayAuthException('登录窗口已关闭或无法打开：$error');
    }
    final result = Uri.parse(callback);
    final returnedState = result.queryParameters['state'];
    if (returnedState != state) {
      throw const GatewayAuthException('登录回调 state 不匹配，已拒绝本次登录。');
    }
    final oauthError = result.queryParameters['error'];
    if (oauthError != null) {
      final description = result.queryParameters['error_description'];
      throw GatewayAuthException(description ?? 'AuthService 登录失败：$oauthError');
    }
    final code = result.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const GatewayAuthException('AuthService 登录回调缺少授权码。');
    }
    return _exchange(
      config: config,
      tokenEndpoint: discovery.tokenEndpoint,
      fields: {
        'grant_type': 'authorization_code',
        'client_id': config.oidcClientId.trim(),
        'redirect_uri': redirect.toString(),
        'code': code,
        'code_verifier': verifier,
      },
    );
  }

  Future<GatewayAuthSession> refresh(
    GatewayConfig config,
    GatewayAuthSession current,
  ) async {
    if (current.refreshToken.trim().isEmpty) {
      throw const GatewayAuthException('登录已过期且没有 Refresh Token，请重新登录。');
    }
    final discovery = await _discovery(config);
    final refreshed = await _exchange(
      config: config,
      tokenEndpoint: discovery.tokenEndpoint,
      fields: {
        'grant_type': 'refresh_token',
        'client_id': config.oidcClientId.trim(),
        'refresh_token': current.refreshToken,
        'scope': 'openid profile email offline_access',
      },
      fallbackRefreshToken: current.refreshToken,
    );
    return refreshed.subject.isEmpty
        ? GatewayAuthSession(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken,
            expiresAt: refreshed.expiresAt,
            subject: current.subject,
            displayName: current.displayName,
          )
        : refreshed;
  }

  Future<_OidcDiscovery> _discovery(GatewayConfig config) async {
    final base = Uri.parse(config.normalizedAuthServiceUrl);
    final uri = base.replace(
      path:
          '${base.path.replaceFirst(RegExp(r'/$'), '')}/.well-known/openid-configuration',
    );
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        uri.toString(),
        options: Options(receiveTimeout: const Duration(seconds: 15)),
      );
      final data = response.data;
      if (data == null) {
        throw const GatewayAuthException('AuthService 返回空发现文档。');
      }
      final issuer = data['issuer']?.toString() ?? '';
      final authorizationEndpoint =
          data['authorization_endpoint']?.toString() ?? '';
      final tokenEndpoint = data['token_endpoint']?.toString() ?? '';
      if (_trimSlash(issuer) != _trimSlash(config.normalizedAuthServiceUrl)) {
        throw const GatewayAuthException('AuthService issuer 与配置地址不一致。');
      }
      _validateEndpoint(authorizationEndpoint, base, 'authorization_endpoint');
      _validateEndpoint(tokenEndpoint, base, 'token_endpoint');
      return _OidcDiscovery(
        authorizationEndpoint: authorizationEndpoint,
        tokenEndpoint: tokenEndpoint,
      );
    } on GatewayAuthException {
      rethrow;
    } on DioException catch (error) {
      throw GatewayAuthException(_dioMessage(error, '读取 AuthService 配置'));
    }
  }

  Future<GatewayAuthSession> _exchange({
    required GatewayConfig config,
    required String tokenEndpoint,
    required Map<String, String> fields,
    String fallbackRefreshToken = '',
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        tokenEndpoint,
        data: fields,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          receiveTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 20),
        ),
      );
      final data = response.data ?? const <String, dynamic>{};
      final accessToken = data['access_token']?.toString() ?? '';
      if (accessToken.isEmpty) {
        throw const GatewayAuthException('AuthService 没有返回 Access Token。');
      }
      final claims = _jwtClaims(data['id_token']?.toString() ?? accessToken);
      final accessClaims = _jwtClaims(accessToken);
      final subject = (claims['sub'] ?? accessClaims['sub'] ?? '').toString();
      final displayName =
          (claims['preferred_username'] ??
                  claims['name'] ??
                  accessClaims['preferred_username'] ??
                  accessClaims['name'] ??
                  subject)
              .toString();
      final expiresIn = int.tryParse(data['expires_in']?.toString() ?? '');
      final exp = (accessClaims['exp'] as num?)?.toInt();
      final expiresAt = expiresIn != null
          ? DateTime.now().toUtc().add(Duration(seconds: expiresIn))
          : exp != null
          ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true)
          : DateTime.now().toUtc().add(const Duration(minutes: 10));
      return GatewayAuthSession(
        accessToken: accessToken,
        refreshToken: data['refresh_token']?.toString() ?? fallbackRefreshToken,
        expiresAt: expiresAt,
        subject: subject,
        displayName: displayName.isEmpty ? subject : displayName,
      );
    } on GatewayAuthException {
      rethrow;
    } on DioException catch (error) {
      final data = error.response?.data;
      String? detail;
      if (data is Map) {
        detail =
            data['error_description']?.toString() ?? data['error']?.toString();
      }
      throw GatewayAuthException(
        detail ?? _dioMessage(error, '交换 AuthService Token'),
      );
    }
  }

  static void _validateConfig(GatewayConfig config) {
    if (!config.authServiceConfigured) {
      throw const GatewayAuthException('请先填写 AuthService 地址、Client ID 和回调地址。');
    }
    final authUri = Uri.tryParse(config.normalizedAuthServiceUrl);
    if (authUri == null || authUri.host.isEmpty || !_isSecure(authUri)) {
      throw const GatewayAuthException(
        'AuthService 必须使用 HTTPS（localhost 开发环境除外）。',
      );
    }
  }

  static void _validateEndpoint(String raw, Uri expectedOrigin, String name) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty || !_isSecure(uri)) {
      throw GatewayAuthException('AuthService $name 无效。');
    }
    if (uri.scheme != expectedOrigin.scheme ||
        uri.host != expectedOrigin.host ||
        uri.port != expectedOrigin.port) {
      throw GatewayAuthException('AuthService $name 指向了不同站点。');
    }
  }

  static bool _isSecure(Uri uri) =>
      uri.scheme == 'https' ||
      (uri.scheme == 'http' &&
          {'localhost', '127.0.0.1', '::1'}.contains(uri.host));

  static String _trimSlash(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');

  static String _randomUrlSafe(int bytes) {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(bytes, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static Map<String, dynamic> _jwtClaims(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return const {};
    try {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      return const {};
    }
  }

  static String _dioMessage(DioException error, String action) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return '$action超时，请检查地址和网络。';
    }
    return '$action失败：${error.message ?? error.type.name}';
  }
}

class _OidcDiscovery {
  const _OidcDiscovery({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
  });

  final String authorizationEndpoint;
  final String tokenEndpoint;
}
