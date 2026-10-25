/// Force standard SFTP v3 no-replace rename on an operation-owned channel.
/// The client consults this public negotiated map before every rename.
void disableClobberingSftpRename(Map<String, String> extensions) {
  try {
    extensions.remove('posix-rename@openssh.com');
  } on UnsupportedError {
    if (extensions.containsKey('posix-rename@openssh.com')) {
      throw StateError('客户端不能禁用覆盖式重命名；安全保存已拒绝');
    }
  }
  if (extensions.containsKey('posix-rename@openssh.com')) {
    throw StateError('无法启用安全的不覆盖重命名，保存已拒绝');
  }
}

/// Preserve the inode found at commit, including late writes through an open
/// editor descriptor. Every rename must use no-replace semantics. Recovery is
/// intentionally retained on success; portable SFTP cannot exclude writers.
Future<String> publishSftpRecovery({
  required String path,
  required String staged,
  required String recovery,
  required String original,
  required Future<String> Function(String path) read,
  required Future<void> Function(String source, String destination) rename,
}) async {
  await rename(path, recovery);
  try {
    if (await read(recovery) != original) {
      throw StateError('远端版本已变化');
    }
    await rename(staged, path);
    return recovery;
  } catch (error) {
    try {
      await rename(recovery, path);
    } catch (_) {
      // A new current name exists; keep it and the original recovery inode.
    }
    throw StateError('安全保存未完成；恢复位置 $recovery（或原路径）：$error');
  }
}
