import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:jose/jose.dart';
import '../../../platform/credentials.dart';
import '../../../platform/preferences.dart';
import 'package:uuid/uuid.dart';
import 'oauth_callback.dart';
import 'chatgpt_network.dart';
import '../model_credentials_unavailable.dart';

class ChatGptAuth {
  ChatGptAuth(this.storage, this.prefs);
  final FlutterSecureStorage storage;
  final SharedPreferences prefs;
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 25),
      followRedirects: false,
    ),
  );
  final _refreshing = <String, Future<String>>{};
  static String key(String id) => 'model_oauth_$id';
  String _random(int count) => base64Url
      .encode(List.generate(count, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  Future<Map<String, dynamic>?> saved(String id) async {
    final raw = await storage.read(key: key(id));
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> signIn(
    String id,
    CancelToken token, {
    void Function(String)? onStage,
  }) async {
    onStage?.call('准备登录网络');
    await configureChatGptNetwork(_dio);
    final previous = await saved(id);
    var host = prefs.getString('chatgptAgentHostId');
    if (host == null) {
      host = 'urn:uuid:${const Uuid().v4()}';
      if (!await prefs.setString('chatgptAgentHostId', host)) {
        throw StateError('无法保存登录主机标识');
      }
    }
    final client = previous?['client_id'] as String? ?? 'dynamic_agent_client';
    final state = _random(32), nonce = _random(32), verifier = _random(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    onStage?.call('等待浏览器授权');
    final callback = await authorizeLoopback(
      (redirect) => Uri.https('auth.openai.com', '/api/accounts/authorize', {
        'client_id': client,
        'ext_agent_host_id': host!,
        if (client == 'dynamic_agent_client') 'agent_name_hint': 'Expert Chat',
        if (previous?['id_token'] != null)
          'id_token_hint': previous!['id_token'] as String,
        'response_type': 'code',
        'redirect_uri': redirect,
        'scope':
            'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
        'resource': 'https://api.openai.com/v1',
        'state': state,
        'nonce': nonce,
        'code_challenge_method': 'S256',
        'code_challenge': challenge,
      }),
      state,
      token,
    );
    if (callback['error'] != null) {
      throw StateError('登录未授权：${callback['error']}');
    }
    if (callback['code']?.isNotEmpty != true) {
      throw StateError('授权回调缺少授权码，请重新登录');
    }
    final issued =
        callback['client_id'] ??
        (client == 'dynamic_agent_client' ? null : client);
    if (issued == null ||
        issued == 'dynamic_agent_client' ||
        client != 'dynamic_agent_client' && issued != client) {
      throw StateError('登录未返回匹配的客户端标识');
    }
    onStage?.call('交换授权凭据');
    final response = await _dio.post<Map<String, dynamic>>(
      'https://auth.openai.com/api/accounts/oauth/token',
      data: {
        'grant_type': 'authorization_code',
        'client_id': issued,
        'code': callback['code'],
        'code_verifier': verifier,
        'redirect_uri': callback['redirect_uri'],
        'resource': 'https://api.openai.com/v1',
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
      cancelToken: token,
    );
    final tokens = response.data!;
    onStage?.call('验证账号身份');
    final discovery = (await _dio.get<Map<String, dynamic>>(
      'https://auth.openai.com/.well-known/openid-configuration',
      cancelToken: token,
    )).data!;
    final jwksUri = Uri.parse(discovery['jwks_uri'] as String);
    if (jwksUri.scheme != 'https' || jwksUri.host != 'auth.openai.com') {
      throw StateError('登录签名服务地址不匹配');
    }
    final keys = (await _dio.get<Map<String, dynamic>>(
      jwksUri.toString(),
      cancelToken: token,
    )).data!;
    final jwt = JsonWebToken.unverified(tokens['id_token'] as String);
    final store = JsonWebKeyStore()..addKeySet(JsonWebKeySet.fromJson(keys));
    if (!await jwt.verify(store) ||
        jwt.claims
            .validate(
              issuer: Uri.parse(discovery['issuer'] as String),
              clientId: issued,
            )
            .isNotEmpty) {
      throw StateError('登录身份校验失败');
    }
    final claims = jwt.claims.toJson();
    if (claims['nonce'] != nonce ||
        claims['sub'] == null ||
        (previous != null && previous['sub'] != claims['sub'])) {
      throw StateError('登录账号与本次授权不匹配');
    }
    if (!(tokens['scope'] as String? ?? '')
        .split(' ')
        .contains('chatgpt.tokens.use.direct')) {
      throw StateError('未授予 ChatGPT 套餐调用权限');
    }
    final record = {
      ...tokens,
      'client_id': issued,
      'sub': claims['sub'],
      'email': claims['email'],
      if (claims['name'] is String) 'name': claims['name'],
      'expires_at': DateTime.now()
          .add(
            Duration(seconds: (tokens['expires_in'] as num?)?.toInt() ?? 3600),
          )
          .toIso8601String(),
    };
    await storage.write(key: key(id), value: jsonEncode(record));
    return record;
  }

  Future<String> accessToken(String id) async {
    final record = await saved(id);
    if (record == null) {
      throw const ModelCredentialsUnavailable('account_not_signed_in');
    }
    final expiry = DateTime.tryParse(record['expires_at'] as String? ?? '');
    if (expiry == null ||
        record['access_token'] is! String ||
        record['client_id'] is! String) {
      throw const ModelCredentialsUnavailable('account_record_incomplete');
    }
    if (expiry.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
      return record['access_token'] as String;
    }
    if (record['refresh_token'] is! String ||
        (record['refresh_token'] as String).isEmpty) {
      throw const ModelCredentialsUnavailable('expired_without_refresh_grant');
    }
    final pending = _refreshing[id];
    if (pending != null) return pending;
    final refresh = _refresh(id, record);
    _refreshing[id] = refresh;
    try {
      return await refresh;
    } finally {
      _refreshing.remove(id);
    }
  }

  Future<String> _refresh(String id, Map<String, dynamic> record) async {
    await configureChatGptNetwork(_dio);
    late Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        'https://auth.openai.com/api/accounts/oauth/token',
        data: {
          'grant_type': 'refresh_token',
          'client_id': record['client_id'],
          'refresh_token': record['refresh_token'],
          'resource': 'https://api.openai.com/v1',
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (error) {
      final body = error.response?.data;
      if ((error.response?.statusCode == 400 ||
              error.response?.statusCode == 401) &&
          body is Map &&
          {'invalid_grant', 'invalid_client'}.contains(body['error'])) {
        throw const ModelCredentialsUnavailable('refresh_grant_rejected');
      }
      rethrow;
    }
    final update = response.data!;
    final next = {
      ...record,
      ...update,
      'expires_at': DateTime.now()
          .add(
            Duration(seconds: (update['expires_in'] as num?)?.toInt() ?? 3600),
          )
          .toIso8601String(),
    };
    await storage.write(key: key(id), value: jsonEncode(next));
    return next['access_token'] as String;
  }

  Future<bool> signOut(String id) async {
    await configureChatGptNetwork(_dio);
    try {
      await _refreshing[id];
    } catch (_) {
      /* Discard an expired grant below. */
    }
    final record = await saved(id);
    var revoked = false;
    try {
      if (record != null) {
        final metadata = (await _dio.get<Map<String, dynamic>>(
          'https://auth.openai.com/.well-known/openid-configuration',
        )).data!;
        final endpoint = Uri.parse(metadata['revocation_endpoint'] as String);
        if (endpoint.scheme != 'https' || endpoint.host != 'auth.openai.com') {
          throw StateError('撤销授权地址不匹配');
        }
        await _dio.post(
          endpoint.toString(),
          data: {
            'token': record['refresh_token'],
            'token_type_hint': 'refresh_token',
            'client_id': record['client_id'],
          },
          options: Options(contentType: Headers.formUrlEncodedContentType),
        );
      }
      revoked = true;
    } catch (_) {
      // Local sign-out still succeeds; the caller reports remote revocation status.
    } finally {
      await storage.delete(key: key(id));
    }
    return revoked;
  }
}
