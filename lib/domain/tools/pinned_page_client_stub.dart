import 'package:dio/dio.dart';

class PinnedPageClient {
  PinnedPageClient({Dio? dio, BaseOptions? options})
    : dio = dio ?? Dio(options);

  final Dio dio;

  Future<List<String>> resolveHost(String host) async => const ['1.1.1.1'];

  void pinHost(String host, List<String> addresses) {}
}
