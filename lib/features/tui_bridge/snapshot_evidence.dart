import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../data/models.dart';
import '../../domain/workbench/changes/line_diff.dart';
import '../../state/work_approvals.dart';
import '../../state/work_changes.dart';

/// Reconstructs expected-version previews from host-observed public evidence.
/// This class performs no I/O and grants no permission to execute an operation.
class TuiSnapshotEvidence {
  TuiSnapshotEvidence({
    required this.conversationId,
    required this.messages,
    required this.changes,
  });
  final String? conversationId;
  final List<ChatMessage> messages;
  final List<WorkFileChange> changes;

  static String stepObject(SearchActivity activity) {
    final args = _object(activity.toolArguments);
    final value = switch (activity.toolName) {
      'coding_read_file' ||
      'coding_write_file' ||
      'coding_list_directory' ||
      'coding_create_directory' ||
      'coding_artifact_manifest' ||
      'work_integrate_agent_file' => args?['path'],
      'work_run_command' || 'work_start_process' => args?['command'],
      'web_search' => args?['query'],
      'fetch_url' => args?['url'],
      'work_spawn_agent' => args?['task'],
      _ => null,
    };
    return value is String && value.trim().isNotEmpty ? value : activity.query;
  }

  static Map<String, dynamic>? _object(String? value) {
    try {
      final decoded = jsonDecode(value ?? '');
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static String? _path(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final normalized = value.replaceAll(r'\', '/');
    if (normalized.split('/').contains('..')) return null;
    return p.posix.normalize(normalized);
  }

  static String _scope(Map<String, dynamic> args) => args['scope'] == null
      ? 'root'
      : args['scope'] is String
      ? args['scope'] as String
      : '';
  static String? _hash(Object? value) {
    if (value is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value)) {
      return null;
    }
    return value.toLowerCase();
  }

  static bool _matchesText(String? text, String? hash) =>
      text != null &&
      hash != null &&
      sha256.convert(utf8.encode(text)).toString() == hash;
  static bool _location(
    Map<String, dynamic> args,
    Map<String, dynamic> receipt,
    String path,
    String scope,
  ) =>
      _path(args['path']) == path &&
      _scope(args) == scope &&
      _path(receipt['path']) == path &&
      _scope(receipt) == scope;

  ({bool known, String? text}) _before({
    required Object? expected,
    required String path,
    required String scope,
    String? messageId,
    DateTime? cutoff,
    String? exclude,
  }) {
    // 'new' is the proposed operation's precondition, not a filesystem claim.
    if (expected == 'new') return (known: true, text: null);
    final hash = _hash(expected);
    if (hash == null) return (known: false, text: null);
    for (final message in messages.reversed) {
      if (messageId != null && message.id != messageId) continue;
      for (final source in message.searchActivities.reversed) {
        if (source.id == exclude ||
            source.status != SearchActivityStatus.done ||
            source.finishedAt == null ||
            cutoff == null ||
            source.finishedAt!.isAfter(cutoff)) {
          continue;
        }
        if (source.toolName != 'coding_read_file' &&
            source.toolName != 'coding_write_file') {
          continue;
        }
        final args = _object(source.toolArguments),
            receipt = _object(source.resultText);
        if (args == null ||
            receipt == null ||
            !_location(args, receipt, path, scope) ||
            _hash(receipt['sha256']) != hash ||
            args['encoding'] == 'base64') {
          continue;
        }
        final content = source.toolName == 'coding_read_file'
            ? receipt['content']
            : args['content'];
        if (content is String && _matchesText(content, hash)) {
          return (known: true, text: content);
        }
      }
    }
    // A stored text snapshot can also supply the exact expected bytes. Never
    // copy aggregate line totals onto individual calls: merged edits differ.
    for (final change in changes.reversed) {
      if (change.conversationId != conversationId ||
          messageId != null && change.assistantId != messageId ||
          change.scope != scope ||
          _path(change.path) != path ||
          !change.textSnapshot) {
        continue;
      }
      if (_hash(change.afterHash) == hash && _matchesText(change.after, hash)) {
        return (known: true, text: change.after);
      }
      if (change.beforeKnown &&
          _hash(change.beforeHash) == hash &&
          _matchesText(change.before, hash)) {
        return (known: true, text: change.before);
      }
    }
    return (known: false, text: null);
  }

  Map<String, Object?> stepLineCounts(
    String messageId,
    SearchActivity activity,
  ) {
    const unknown = <String, Object?>{'added': null, 'removed': null};
    if (activity.toolName != 'coding_write_file' ||
        activity.status != SearchActivityStatus.done) {
      return unknown;
    }
    final args = _object(activity.toolArguments),
        receipt = _object(activity.resultText);
    if (args == null || receipt == null || args['content'] is! String) {
      return unknown;
    }
    final path = _path(args['path']), hash = _hash(receipt['sha256']);
    if (path == null ||
        !_location(args, receipt, path, _scope(args)) ||
        !_matchesText(args['content'] as String, hash)) {
      return unknown;
    }
    final before = _before(
      expected: args['expected_sha256'],
      path: path,
      scope: _scope(args),
      messageId: messageId,
      cutoff: activity.startedAt,
      exclude: activity.id,
    );
    if (!before.known) return unknown;
    final diff = buildLineDiff(before.text, args['content'] as String);
    return {
      'added': diff.where((l) => l.kind == DiffLineKind.added).length,
      'removed': diff.where((l) => l.kind == DiffLineKind.removed).length,
    };
  }

  List<String> approvalDiff(PendingWorkApproval request) {
    if (request.conversationId != conversationId ||
        request.tool != 'coding_write_file') {
      return [];
    }
    final args = _object(request.arguments);
    if (args == null ||
        args['content'] is! String ||
        _path(args['path']) == null) {
      return ['无法预览：写入参数缺少有效路径或文本内容。'];
    }
    final path = _path(args['path'])!;
    final before = _before(
      expected: args['expected_sha256'],
      path: path,
      scope: _scope(args),
      cutoff: DateTime.now(),
    );
    if (!before.known) return ['无法预览：没有与 expected_sha256 匹配的已读取文本；未读取磁盘。'];
    return [
      args['expected_sha256'] == 'new'
          ? '@@ 拟新建文件；执行前仍核验文件不存在 @@'
          : '@@ 已读取的预期哈希版本；执行前仍核验文件版本 @@',
      for (final line in buildLineDiff(before.text, args['content'] as String))
        '${switch (line.kind) {
          DiffLineKind.added => '+',
          DiffLineKind.removed => '-',
          _ => ' ',
        }}${line.text}',
    ];
  }
}
