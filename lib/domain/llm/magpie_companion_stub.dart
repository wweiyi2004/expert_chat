class MagpieCompanion {
  bool get owned => false;
  Future<List<String>> start({
    required String executable,
    required String directory,
    int apiPort = 3425,
    int webPort = 3430,
  }) async => throw UnsupportedError('此平台不启动本地伴随服务');
  Future<List<String>> models({int apiPort = 3425}) async =>
      throw UnsupportedError('请在电脑配置伴随服务');
  Future<void> stopOwned() async {}
  Future<void> openManagement(Future<bool> Function(Uri) launch) async =>
      throw UnsupportedError('请在电脑打开伴随服务');
}
