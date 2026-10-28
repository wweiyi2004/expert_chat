import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../data/full_backup_service.dart';
import '../../data/backup_codec.dart';
import 'host_client.dart';

/// File staging avoids putting a 128 MiB archive into a JSON RPC frame. The
/// host revalidates the exact reviewed bytes before its own restore transaction.
class HostBackupService extends FullBackupService {
  HostBackupService(
    super.db,
    super.files,
    super.memory,
    super.prefs,
    super.journal,
  );
  final _reviewed = Expando<Uint8List>();
  @override
  Future<Uint8List> exportBackup() async {
    final directory = await Directory.systemTemp.createTemp(
      'expert-backup-export-',
    );
    final file = File(p.join(directory.path, 'archive.ecbackup'));
    var retain = false;
    try {
      await HostClient.current!.call('runtime', 'backup.export', {
        'path': file.path,
      });
      if (await file.length() > BackupCodec.maxBytes) {
        throw const FormatException('备份文件超过上限');
      }
      return await file.readAsBytes();
    } on HostRpcException catch (error) {
      retain = error.outcomeUnknown;
      rethrow;
    } finally {
      if (!retain) {
        if (await file.exists()) await file.delete();
        if (await directory.exists()) await directory.delete();
      }
    }
  }

  @override
  Future<BackupPreview> preview(Uint8List bytes) async {
    final immutable = Uint8List.fromList(bytes),
        result = await super.preview(bytes);
    _reviewed[result] = immutable;
    return result;
  }

  @override
  Future<void> restoreCopies(
    BackupPreview preview, {
    bool restorePreferences = false,
  }) async {
    final bytes = _reviewed[preview];
    if (bytes == null) throw StateError('请重新选择并核对备份');
    final directory = await Directory.systemTemp.createTemp(
      'expert-backup-import-',
    );
    final file = File(p.join(directory.path, 'archive.ecbackup'));
    var retain = false;
    try {
      await file.writeAsBytes(bytes, flush: true);
      await HostClient.current!.call('runtime', 'backup.restore', {
        'path': file.path,
        'sha256': sha256.convert(bytes).toString(),
        'restorePreferences': restorePreferences,
      });
      await prefs.reload();
    } on HostRpcException catch (error) {
      retain = error.outcomeUnknown;
      rethrow;
    } finally {
      if (!retain) {
        if (await file.exists()) await file.delete();
        if (await directory.exists()) await directory.delete();
      }
    }
  }

  @override
  Future<void> recoverPending() async {
    // Startup recovery belongs exclusively to the execution host.
  }
}
