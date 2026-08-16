import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

class PinnedPageClient {
  PinnedPageClient({Dio? dio, BaseOptions? options}) {
    final client = dio ?? Dio(options);
    this.dio = client;
    if (dio == null) {
      client.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: _createHttpClient,
      );
    }
  }

  late final Dio dio;
  final Map<String, List<InternetAddress>> _pinnedAddresses = {};

  Future<List<String>> resolveHost(String host) async {
    final addresses = await InternetAddress.lookup(host);
    return addresses.map((address) => address.address).toList(growable: false);
  }

  void pinHost(String host, List<String> addresses) {
    _pinnedAddresses[host.toLowerCase()] = addresses
        .map(InternetAddress.new)
        .toList(growable: false);
  }

  HttpClient _createHttpClient() {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (url, proxyHost, proxyPort) async {
      if (proxyHost != null || proxyPort != null) {
        throw const SocketException('Proxies are disabled for page fetching');
      }

      final addresses = _pinnedAddresses[url.host.toLowerCase()];
      if (addresses == null || addresses.isEmpty) {
        throw SocketException('No validated address for ${url.host}');
      }

      final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
      final socketTask = await startConnectPinned(
        addresses: addresses,
        port: port,
        host: url.host,
      );
      if (url.scheme != 'https') {
        return socketTask;
      }

      final secureSocket = socketTask.socket.then<Socket>(
        (socket) => SecureSocket.secure(socket, host: url.host),
      );
      return ConnectionTask.fromSocket(secureSocket, socketTask.cancel);
    };
    return client;
  }
}

/// Tries each already-validated address. [Socket.startConnect] only accepts a
/// hostname [String] or a single [InternetAddress]; a [List] throws TypeError.
Future<ConnectionTask<Socket>> startConnectPinned({
  required List<InternetAddress> addresses,
  required int port,
  required String host,
}) async {
  Object? lastError;
  for (var i = 0; i < addresses.length; i++) {
    final isLast = i == addresses.length - 1;
    try {
      final task = await Socket.startConnect(addresses[i], port);
      if (isLast) return task;
      try {
        final socket = await task.socket;
        return ConnectionTask.fromSocket(
          Future<Socket>.value(socket),
          task.cancel,
        );
      } catch (error) {
        lastError = error;
      }
    } on SocketException catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? SocketException('No validated address for $host');
}
