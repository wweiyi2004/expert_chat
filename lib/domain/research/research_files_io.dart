import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'research_files.dart';
import 'research_safe_save.dart';

/// Each operation captures the authenticated connection and owns its SFTP
/// channel. File errors never tear down the interactive terminal.
class SshResearchFiles
    implements ResearchFiles, ResearchBinaryFiles, ResearchRecoveryFiles {
  SshResearchFiles(this.client);
  final SSHClient client;
  final _recoveryPaths = <String, String>{};
  @override
  String? recoveryPathFor(String path) => _recoveryPaths[path];
  static const _timeout = Duration(seconds: 30);
  static const maxTextBytes = 1024 * 1024;
  static final _downloadTargets = <String>{};

  Future<T> _withSftp<T>(Future<T> Function(SftpClient) work) async {
    final opening = client.sftp();
    SftpClient? channel;
    var timedOut = false;
    unawaited(
      opening.then((value) async {
        if (timedOut) await value.close();
      }, onError: (Object _) {}),
    );
    try {
      channel = await opening.timeout(
        _timeout,
        onTimeout: () {
          timedOut = true;
          throw TimeoutException('SFTP 连接超时');
        },
      );
      return await work(channel);
    } finally {
      if (channel != null) {
        try {
          await channel.close().timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
    }
  }

  @override
  Future<String> absolute(String path) =>
      _withSftp((s) => s.absolute(path).timeout(_timeout));
  @override
  Future<List<ResearchRemoteFile>> list(String path) => _withSftp((s) async {
    final entries = await s.listdir(path).timeout(_timeout);
    final files = [
      for (final e in entries)
        if (e.filename != '.' &&
            e.filename != '..' &&
            !e.filename.contains('/') &&
            !e.filename.contains('\u0000'))
          ResearchRemoteFile(
            name: e.filename,
            path: p.posix.join(path, e.filename),
            directory: e.attr.isDirectory,
            size: e.attr.size ?? 0,
            modifiedTime: e.attr.modifyTime,
            symbolicLink: e.attr.isSymbolicLink,
          ),
    ];
    files.sort(
      (a, b) => a.directory != b.directory
          ? (a.directory ? -1 : 1)
          : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return files;
  });
  Future<String> _read(SftpClient s, String path) async {
    final attrs = await s.stat(path).timeout(_timeout);
    if ((attrs.size ?? maxTextBytes + 1) > maxTextBytes || attrs.isDirectory) {
      throw StateError('仅支持编辑 1 MB 以内的 UTF-8 文本，请下载较大文件');
    }
    final file = await s.open(path).timeout(_timeout);
    try {
      final bytes = await file
          .readBytes(length: maxTextBytes + 1)
          .timeout(_timeout);
      if (bytes.length > maxTextBytes || bytes.contains(0)) {
        throw StateError('文件过大或不是文本');
      }
      return utf8.decode(bytes);
    } finally {
      await file.close().timeout(_timeout);
    }
  }

  @override
  Future<List<int>> readBytes(String path, {int maxBytes = 8 * 1024 * 1024}) =>
      _withSftp((s) async {
        final attributes = await s.stat(path).timeout(_timeout);
        if (attributes.isDirectory ||
            (attributes.size ?? maxBytes + 1) > maxBytes) {
          throw StateError('图片预览最多支持 8 MiB');
        }
        final file = await s.open(path).timeout(_timeout);
        try {
          final bytes = await file
              .readBytes(length: maxBytes + 1)
              .timeout(_timeout);
          if (bytes.length > maxBytes) throw StateError('图片预览最多支持 8 MiB');
          return bytes;
        } finally {
          await file.close().timeout(_timeout);
        }
      });

  @override
  Future<String> readText(String path) => _withSftp((s) => _read(s, path));
  @override
  Future<void> saveText(
    String path,
    String content, {
    required String original,
  }) => _withSftp((s) async {
    // This operation owns its SFTP channel. dartssh2 exposes the negotiated
    // extension map and consults it on every rename. Disable its automatic
    // clobbering extension on this private channel to force SFTP v3 RENAME.
    final handshake = await s.handshake.timeout(_timeout);
    disableClobberingSftpRename(handshake.extensions);
    final data = Uint8List.fromList(utf8.encode(content));
    if (data.length > maxTextBytes) throw StateError('文本超过 1 MB');
    if (await _read(s, path) != original) {
      throw StateError('远端文件已变化，请重新打开后合并修改');
    }
    final attrs = await s.stat(path).timeout(_timeout);
    final temp = '$path.expert-chat-${const Uuid().v4()}.tmp';
    var created = false;
    try {
      final file = await s
          .open(
            temp,
            mode:
                SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.exclusive,
          )
          .timeout(_timeout);
      created = true;
      try {
        await file.writeBytes(data).timeout(_timeout);
      } finally {
        await file.close().timeout(_timeout);
      }
      if (attrs.mode != null) {
        await s
            .setStat(temp, SftpFileAttrs(mode: attrs.mode))
            .timeout(_timeout);
      }
      final recovery = '$path.expert-chat-recovery-${const Uuid().v4()}';
      _recoveryPaths[path] = await publishSftpRecovery(
        path: path,
        staged: temp,
        recovery: recovery,
        original: original,
        read: (value) => _read(s, value),
        rename: (source, destination) =>
            s.rename(source, destination).timeout(_timeout),
      );
      created = false;
    } finally {
      if (created) {
        try {
          await s.remove(temp).timeout(_timeout);
        } catch (_) {}
      }
    }
  });
  @override
  Future<void> mkdir(String path) =>
      _withSftp((s) => s.mkdir(path).timeout(_timeout));
  @override
  Future<void> download(
    String remote,
    String local, {
    required ResearchTransferToken token,
    required void Function(int, int) progress,
  }) async {
    final target = File(p.normalize(p.absolute(local)));
    final parent = await target.parent.resolveSymbolicLinks();
    final resolved = p.join(parent, p.basename(target.path));
    final key = Platform.isWindows ? resolved.toLowerCase() : resolved;
    if (!_downloadTargets.add(key)) throw StateError('该文件正在下载');
    Directory? staging;
    try {
      token.check();
      // A private directory is created exclusively on the same filesystem.
      // Never truncate a user file or another task's partial download.
      staging = await Directory(parent).createTemp('.expert-chat-download-');
      final partial = File(p.join(staging.path, 'download.part'));
      await _withSftp((s) async {
        token.check();
        final attrs = await s.stat(remote).timeout(_timeout);
        final file = await s.open(remote).timeout(_timeout);
        try {
          final output = await partial.open(mode: FileMode.write);
          var count = 0;
          try {
            await for (final chunk in file.read().timeout(_timeout)) {
              token.check();
              await output.writeFrom(chunk);
              count += chunk.length;
              progress(count, attrs.size ?? -1);
            }
            token.check();
            if (attrs.size != null && count != attrs.size) {
              throw StateError('文件未下载完整');
            }
          } finally {
            await output.close();
          }
        } finally {
          await file.close().timeout(_timeout);
        }
      });
      token.check();
      await partial.rename(target.path);
    } finally {
      try {
        if (staging != null) {
          final partial = File(p.join(staging.path, 'download.part'));
          if (await partial.exists()) await partial.delete();
          await staging.delete();
        }
      } finally {
        _downloadTargets.remove(key);
      }
    }
  }

  @override
  Future<void> upload(
    String local,
    String remote, {
    required ResearchTransferToken token,
    required void Function(int, int) progress,
  }) => _withSftp((s) async {
    token.check();
    final input = File(local);
    final total = await input.length();
    // Exclusive creation: never silently overwrite an existing remote file.
    final output = await s
        .open(
          remote,
          mode:
              SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.exclusive,
        )
        .timeout(_timeout);
    var count = 0;
    var complete = false;
    try {
      await for (final chunk in input.openRead()) {
        token.check();
        await output
            .writeBytes(Uint8List.fromList(chunk), offset: count)
            .timeout(_timeout);
        count += chunk.length;
        progress(count, total);
      }
      token.check();
      if (count != total) throw StateError('本地文件在传输中变化');
      complete = true;
    } finally {
      await output.close().timeout(_timeout);
      if (!complete) {
        try {
          await s.remove(remote).timeout(_timeout);
        } catch (_) {}
      }
    }
  });
}
