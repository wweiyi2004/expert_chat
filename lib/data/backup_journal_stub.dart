class BackupJournal {
  BackupJournal({this.pathOverride});
  final String? pathOverride;
  Future<Map<String, dynamic>?> read() async => null;
  Future<void> write(Map<String, dynamic> value) async =>
      throw UnsupportedError('完整恢复暂仅支持桌面和移动应用。');
  Future<void> clear() async {}
}
