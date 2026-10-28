class ResearchRemoteFile {
  const ResearchRemoteFile({
    required this.name,
    required this.path,
    required this.directory,
    this.size = 0,
    this.modifiedTime,
    this.symbolicLink = false,
  });
  final String name, path;
  final bool directory;
  final int size;
  final int? modifiedTime;
  final bool symbolicLink;
}

class ResearchTransferToken {
  bool cancelled = false;
  void check() {
    if (cancelled) throw StateError('传输已取消');
  }
}

/// Optional bounded image/file previews, separate from editable UTF-8 text.
abstract interface class ResearchBinaryFiles {
  Future<List<int>> readBytes(String path, {int maxBytes = 8 * 1024 * 1024});
}

/// Successful safe saves may retain an inode that a concurrent editor still
/// owns. Surface its exact recovery location; never clean it automatically.
abstract interface class ResearchRecoveryFiles {
  String? recoveryPathFor(String path);
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
