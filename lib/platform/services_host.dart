import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'paths_host.dart';

class PlatformException implements Exception {
  PlatformException({
    required this.code,
    this.message,
    this.details,
    this.stacktrace,
  });
  final String code;
  final String? message, stacktrace;
  final Object? details;
  @override
  String toString() => 'PlatformException($code, $message)';
}

class MissingPluginException implements Exception {
  MissingPluginException([this.message]);
  final String? message;
}

class MethodChannel {
  const MethodChannel(this.name);
  final String name;
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    if (name == 'expert_chat/device_agent' && method == 'status') {
      return <String, dynamic>{'enabled': false, 'armed': false} as T;
    }
    throw MissingPluginException('此能力由已连接的图形客户端提供：$name/$method');
  }

  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    Object? arguments,
  ]) async => (await invokeMethod<Map>(method, arguments))?.cast<K, V>();
}

class HostAssetBundle {
  const HostAssetBundle();
  File _asset(String key) {
    if (p.isAbsolute(key) || p.split(key).contains('..')) {
      throw ArgumentError('Invalid bundled asset');
    }
    final root =
        HostPaths.assetsDirectory ??
        Platform.environment['EXPERT_HOST_ASSETS'] ??
        p.join(HostPaths.bundleDirectory, 'data', 'flutter_assets');
    return File(p.join(root, key));
  }

  Future<String> loadString(String key, {bool cache = true}) =>
      _asset(key).readAsString();
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await _asset(key).readAsBytes());
}

const rootBundle = HostAssetBundle();
