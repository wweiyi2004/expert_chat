import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../../features/tui_bridge/protocol.dart';

/// Records admission before a side effect. A restart never replays a mutation.
/// Only keyed digests and receipt state are persisted, never arguments/results.
class HostOperationLedger {
  HostOperationLedger._(this.file, this._salt);
  final File file;
  final List<int> _salt;
  final _entries = <String, Map<String, dynamic>>{};
  final _live =
      <String, ({String fingerprint, Future<Map<String, Object?>> result})>{};
  Future<void> _writes = Future.value();
  bool _closing = false;
  Object? _writeFailure;
  static const maxBytes = 64 * 1024 * 1024;
  static Future<HostOperationLedger> open(File file) async {
    await file.parent.create(recursive: true);
    if (!await file.exists() || await file.length() == 0) {
      final random = Random.secure();
      final salt = List<int>.generate(32, (_) => random.nextInt(256));
      await file.writeAsString(
        '${jsonEncode({'version': 1, 'salt': base64Encode(salt)})}\n',
        flush: true,
      );
    }
    if (await file.length() > maxBytes) throw StateError('操作回执日志超出限制，请先归档资料');
    final bytes = await file.readAsBytes();
    final end = bytes.lastIndexOf(10);
    if (end < 0) throw StateError('操作回执日志损坏，已保留原文件');
    if (end != bytes.length - 1) {
      // A torn last record cannot have authorized an operation: admission is
      // awaited before execution. A torn completion retains its admission.
      await file.copy(
        '${file.path}.interrupted-${DateTime.now().microsecondsSinceEpoch}',
      );
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.truncate(end + 1);
        await handle.flush();
      } finally {
        await handle.close();
      }
    }
    final lines = utf8
        .decode(bytes.sublist(0, end + 1))
        .split('\n')
        .where((s) => s.isNotEmpty)
        .toList();
    final header = jsonDecode(lines.first) as Map;
    if (header['version'] != 1) throw StateError('操作回执版本不兼容');
    final salt = base64Decode(header['salt'] as String);
    if (salt.length != 32) throw StateError('操作回执日志损坏');
    final ledger = HostOperationLedger._(file, salt);
    for (final line in lines.skip(1)) {
      final entry = Map<String, dynamic>.from(jsonDecode(line) as Map);
      final key = entry['key'], fingerprint = entry['fingerprint'];
      if (key is! String ||
          fingerprint is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
          !['admitted', 'completed', 'failed'].contains(entry['state'])) {
        throw StateError('操作回执日志损坏，已保留原文件');
      }
      final old = ledger._entries[key];
      if (old != null &&
          (old['fingerprint'] != fingerprint || old['state'] != 'admitted')) {
        throw StateError('操作回执顺序无效，已保留原文件');
      }
      ledger._entries[key] = entry;
    }
    return ledger;
  }

  String _digest(Object value) =>
      Hmac(sha256, _salt).convert(utf8.encode(jsonEncode(value))).toString();
  Future<void> _append(Map<String, dynamic> entry) {
    final next = _writes.then((_) async {
      if (_writeFailure != null) throw StateError('操作回执未可靠保存，宿主拒绝接受新操作');
      final bytes = utf8.encode('${jsonEncode(entry)}\n');
      if (await file.length() + bytes.length > maxBytes) {
        throw StateError('操作回执日志已满');
      }
      await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
      _entries[entry['key'] as String] = entry;
    });
    _writes = next.catchError((Object error) {
      _writeFailure = error;
    });
    return next;
  }

  Future<Map<String, Object?>> execute(
    String requestId,
    String method,
    Map<String, dynamic> params,
    Future<Map<String, Object?>> Function() action,
  ) {
    if (_closing || _writeFailure != null) {
      throw const BridgeFailure('closing', '宿主未接受操作，请核验持久化状态');
    }
    final key = _digest(requestId);
    final fingerprint = _digest([
      method,
      {
        for (final e in params.entries)
          if (!e.key.startsWith('_bridge_')) e.key: e.value,
      },
    ]);
    final live = _live[key];
    if (live != null) {
      if (live.fingerprint != fingerprint) {
        throw const BridgeFailure('conflict', '请求标识已用于其他内容');
      }
      return live.result;
    }
    final previous = _entries[key];
    if (previous != null) {
      if (previous['fingerprint'] != fingerprint) {
        throw const BridgeFailure('conflict', '请求标识已用于其他内容');
      }
      throw const BridgeFailure(
        'unknown_result',
        '此操作已有持久化回执，但结果内容不在当前缓存中；请核对状态。宿主没有重复执行。',
      );
    }
    final result = (() async {
      final entry = <String, dynamic>{
        'key': key,
        'fingerprint': fingerprint,
        'state': 'admitted',
        'time': DateTime.now().toUtc().toIso8601String(),
      };
      await _append(entry);
      try {
        final value = await action();
        await _append({...entry, 'state': 'completed'});
        return value;
      } catch (_) {
        if (_writeFailure == null) await _append({...entry, 'state': 'failed'});
        rethrow;
      }
    })();
    _live[key] = (fingerprint: fingerprint, result: result);
    void trim() {
      // Eviction discards only the in-memory result; durable admission remains.
      if (_live.length > 512) _live.remove(key);
    }

    unawaited(result.then<void>((_) => trim(), onError: (Object _) => trim()));
    return result;
  }

  Future<void> close() async {
    _closing = true;
    await _writes;
  }
}
