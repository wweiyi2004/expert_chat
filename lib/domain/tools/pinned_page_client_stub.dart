import 'package:dio/dio.dart';

class PinnedPageClient {
  PinnedPageClient({Dio? dio, BaseOptions? options})
    : dio = dio ?? Dio(options);

  final Dio dio;

  /// Browser builds cannot resolve and pin DNS independently of the browser.
  /// Returning no addresses makes secure direct page fetching fail closed.
  Future<List<String>> resolveHost(String host) async => const [];

  void pinHost(String host, List<String> addresses) {}
}
