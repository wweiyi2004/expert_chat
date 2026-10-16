class ResearchRemoteFile {
  const ResearchRemoteFile({
    required this.name,
    required this.path,
    required this.directory,
    this.size = 0,
  });
  final String name, path;
  final bool directory;
  final int size;
}

class ResearchTransferToken {
  bool cancelled = false;
  void check() {
    if (cancelled) throw StateError('传输已取消');
  }
}

abstract interface class ResearchFilesHost {
  ResearchFiles get files;
}

abstract interface class ResearchFiles {
  Future<String> absolute(String path);
  Future<List<ResearchRemoteFile>> list(String path);
  Future<String> readText(String path);
  Future<void> saveText(
    String path,
    String content, {
    required String original,
  });
  Future<void> mkdir(String path);
  Future<void> download(
    String remote,
    String local, {
    required ResearchTransferToken token,
    required void Function(int, int) progress,
  });
  Future<void> upload(
    String local,
    String remote, {
    required ResearchTransferToken token,
    required void Function(int, int) progress,
  });
}
