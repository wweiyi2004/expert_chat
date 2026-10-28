class FlutterWebAuth2Options {
  const FlutterWebAuth2Options({
    this.useWebview = false,
    this.timeout = 300,
    this.httpsHost,
    this.httpsPath,
  });
  final bool useWebview;
  final int timeout;
  final String? httpsHost, httpsPath;
}

class FlutterWebAuth2 {
  static Future<String> Function(
    String url,
    String callbackScheme,
    FlutterWebAuth2Options options,
  )?
  clientAuthorize;
  static Future<String> authenticate({
    required String url,
    required String callbackUrlScheme,
    FlutterWebAuth2Options options = const FlutterWebAuth2Options(),
  }) async {
    final authorize = clientAuthorize;
    if (authorize == null) {
      throw UnsupportedError('此登录方式需要连接图形客户端；已保存的令牌仍可由宿主刷新');
    }
    return authorize(url, callbackUrlScheme, options);
  }
}
