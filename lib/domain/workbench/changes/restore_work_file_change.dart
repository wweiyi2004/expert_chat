import 'package:dio/dio.dart';
import '../../desktop/workspace_tools.dart';
import 'work_file_change.dart';

/// The caller resolves and validates the captured original target first. Every
/// mutation below still uses that session's ordinary authority and exact hash.
Future<String> restoreReviewedFileChange(
  WorkToolSession session,
  WorkFileChange change,
  CancelToken token,
) {
  if (change.recreateNewFile) {
    if (!change.isNew || !change.reverted || !change.beforeKnown) {
      throw StateError('仅可从已撤销新文件的完整快照重新创建');
    }
    return session.call('coding_write_file', {
      'scope': change.scope,
      'path': change.path,
      'content': change.after,
      'expected_sha256': 'new',
    }, token);
  }
  if (!change.canRestore) throw StateError('该记录不支持撤销');
  return session.call(
    change.isNew ? 'coding_delete_file_if_current' : 'coding_write_file',
    {
      'scope': change.scope,
      'path': change.path,
      if (!change.isNew) 'content': change.before!,
      'expected_sha256': change.afterHash,
    },
    token,
  );
}
