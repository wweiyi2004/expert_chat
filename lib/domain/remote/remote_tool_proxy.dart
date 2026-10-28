import 'dart:convert';
import 'package:dio/dio.dart';
import '../../platform/credentials.dart';

/// Each call snapshots a selected paired host; changing the selector cannot
/// redirect a request already in flight to a different computer.
class RemoteToolProxy {
  RemoteToolProxy({this.snapshotPair = false});
  final bool snapshotPair;
  Future<Map<String, dynamic>?>? _captured;
  final _storage = const FlutterSecureStorage();
  Future<Map<String, dynamic>?> _pair() =>
      snapshotPair ? (_captured ??= _readPair()) : _readPair();
  Future<Map<String, dynamic>?> _readPair() async {
    final raw = await _storage.read(key: 'remote_host_pair_v1');
    if (raw == null) return null;
    final pair = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final uri = Uri.parse(pair['url'] as String);
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw StateError('Invalid paired host');
    }
    final loopback = ['127.0.0.1', 'localhost', '::1'].contains(uri.host);
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' &&
            (loopback || pair['protectedTunnel'] == true))) {
      throw StateError('Paired host requires TLS or protected tunnel');
    }
    pair['url'] = (pair['url'] as String).replaceFirst(RegExp(r'/+$'), '');
    return pair;
  }

  Future<bool> get available async {
    final pair = await _pair();
    if (pair == null) return false;
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        followRedirects: false,
      ),
    );
    try {
      final result = await dio.get<dynamic>(
        '${pair['url']}/v1/tools',
        options: Options(headers: {'Authorization': 'Bearer ${pair['token']}'}),
      );
      return result.data['math'] == true;
    } catch (_) {
      return false;
    } finally {
      dio.close(force: true);
    }
  }

  Future<String> executeMath(
    Map<String, dynamic> arguments, {
    CancelToken? cancelToken,
  }) async {
    final pair = await _pair();
    if (pair == null) throw StateError('请先在工具 → 远程电脑任务配对支持数学工具的电脑');
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 90),
        followRedirects: false,
      ),
    );
    try {
      final response = await dio.post<dynamic>(
        '${pair['url']}/v1/tools/math',
        data: arguments,
        cancelToken: cancelToken,
        options: Options(headers: {'Authorization': 'Bearer ${pair['token']}'}),
      );
      return response.data['result'] as String;
    } finally {
      dio.close(force: true);
    }
  }
}
