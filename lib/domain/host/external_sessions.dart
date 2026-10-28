import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../../platform/media_worker.dart';

/// Imports conversation text only. Credentials, system instructions, tool calls,
/// approvals and source-session execution state never cross the boundary.
class ExternalSessionCandidate {
  ExternalSessionCandidate(
    this.source,
    this.key,
    this.title,
    this.cwd,
    this.updated,
    this.messages,
  );
  final String source, key, title, cwd;
  final DateTime updated;
  final List<Map<String, String>> messages;
  String get fingerprint =>
      sha256.convert(utf8.encode(jsonEncode(messages))).toString();
  String get id => sha256.convert(utf8.encode('$source\n$key')).toString();
  Map<String, Object?> summary() => {
    'id': id,
    'source': source,
    'title': title,
    'cwd': cwd,
    'updated': updated.toUtc().toIso8601String(),
    'messages': messages.length,
    'fingerprint': fingerprint,
  };
}

List<Map<String, String>> parseExternalMessages(String source, String raw) {
  final result = <Map<String, String>>[];
  final seen = <String>{};
  String content(Object? v) {
    if (v is String) return v;
    if (v is List) {
      return v
          .map((e) {
            if (e is! Map) return '';
            if (!{'text', 'input_text', 'output_text'}.contains(e['type'])) {
              return '';
            }
            return e['text'] is String ? e['text'] as String : '';
          })
          .where((v) => v.isNotEmpty)
          .join('\n');
    }
    if (v is Map && v['text'] is String) return v['text'] as String;
    return '';
  }

  void add(Object? role, Object? value, {String? id, bool chunk = false}) {
    if (role != 'user' && role != 'assistant') return;
    final text = chunk ? content(value) : content(value).trim();
    if (text.isEmpty) return;
    if (id != null && !seen.add(id)) return;
    if (chunk && result.isNotEmpty && result.last['role'] == role) {
      result.last['text'] = '${result.last['text']}$text';
    } else {
      result.add({'role': role as String, 'text': text});
    }
  }

  final values = <dynamic>[];
  try {
    final v = jsonDecode(raw);
    if (v is Map && v['messages'] is List) {
      values.addAll(v['messages'] as List);
    } else if (v is List) {
      values.addAll(v);
    } else {
      values.add(v);
    }
  } catch (_) {
    for (final line in const LineSplitter().convert(raw)) {
      try {
        values.add(jsonDecode(line));
      } catch (_) {}
    }
  }
  for (final v in values) {
    if (v is! Map || v['isSidechain'] == true) continue;
    if (source == 'Grok Build') {
      final params = v['params'];
      final update = params is Map ? params['update'] : null;
      if (update is Map) {
        final kind = update['sessionUpdate'];
        final meta = params is Map ? params['_meta'] : null;
        if (kind == 'user_message_chunk' || kind == 'agent_message_chunk') {
          add(
            kind == 'user_message_chunk' ? 'user' : 'assistant',
            update['content'],
            id: meta is Map ? meta['eventId'] as String? : null,
            chunk: true,
          );
        }
        continue;
      }
    }
    if (source == 'DeepSeek Harness') {
      final data = v['data'];
      if (data is Map) {
        if (v['type'] == 'user/message') {
          add('user', data['content'], id: data['id'] as String?);
        }
        if (v['type'] == 'assistant/message' && data['message'] is Map) {
          final m = data['message'] as Map;
          add('assistant', m['content'], id: m['id'] as String?);
        }
        if (v['type'] == 'agent/inbox/spliced' && data['inserted'] is List) {
          for (final m in data['inserted'] as List) {
            if (m is Map) add(m['role'], m['content'], id: m['id'] as String?);
          }
        }
        continue;
      }
    }
    final payload = v['payload'];
    if (source == 'Codex') {
      if (v['type'] == 'response_item' &&
          payload is Map &&
          payload['type'] == 'message') {
        add(payload['role'], payload['content'], id: payload['id'] as String?);
      }
      continue;
    }
    final m = v['message'] is Map ? v['message'] as Map : v;
    add(
      m['role'] ?? v['type'],
      m['content'] ?? m['text'],
      id: (m['id'] ?? v['uuid']) as String?,
    );
  }
  var size = 0;
  final bounded = <Map<String, String>>[];
  for (final m in result.reversed) {
    final text = m['text']!;
    if (bounded.length >= 200 || size + text.length > 240000) break;
    bounded.add(m);
    size += text.length;
  }
  return bounded.reversed.toList();
}

class ExternalSessionService {
  ExternalSessionService({String? home})
    : home =
          home ??
          Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
  final String home;
  final _candidates = <String, ExternalSessionCandidate>{};
  final _reload = <String, Future<ExternalSessionCandidate?> Function()>{};

  String _ioPath(String path) {
    if (!Platform.isWindows || path.startsWith(r'\\?\')) return path;
    if (path.startsWith(r'\\')) return r'\\?\UNC\' + path.substring(2);
    return r'\\?\' + p.absolute(path);
  }

  /// One stale, inaccessible or long legacy session directory must not abort
  /// discovery for all clients. Windows extended paths avoid MAX_PATH failures.
  Future<List<File>> _recentFiles(Directory root) async {
    final pending = <Directory>[Directory(_ioPath(root.path))];
    final files = <({File file, DateTime modified})>[];
    var examined = 0;
    while (pending.isNotEmpty && examined < 16000) {
      final directory = pending.removeLast();
      try {
        await for (final entry in directory.list(followLinks: false)) {
          if (++examined > 16000) break;
          if (entry is Directory) {
            pending.add(entry);
          } else if (entry is File &&
              (entry.path.endsWith('.jsonl') ||
                  entry.path.endsWith('.jsonl.zstd')) &&
              !p.basename(entry.path).startsWith('prompt_history')) {
            try {
              final stat = await entry.stat();
              if (stat.type == FileSystemEntityType.file) {
                files.add((file: entry, modified: stat.modified));
              }
            } on FileSystemException {
              /* File disappeared during scanning. */
            }
          }
        }
      } on FileSystemException {
        /* Preserve other directories and sources. */
      }
    }
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return files.take(8).map((e) => e.file).toList();
  }

  Future<ExternalSessionCandidate?> _file(String source, File file) async {
    final stat = await file.stat();
    if (stat.size > 15 * 1024 * 1024 || stat.size == 0) return null;
    String raw;
    if (file.path.endsWith('.zstd')) {
      final request = {
        'op': 'session_zstd',
        'data': base64Encode(await file.readAsBytes()),
      };
      raw =
          (await Isolate.run(() => runMediaWorker(request)))['text'] as String;
    } else {
      raw = await file.readAsString();
    }
    final messages = parseExternalMessages(source, raw);
    if (messages.isEmpty) return null;
    var cwd = '';
    var title = '';
    for (final line in const LineSplitter().convert(raw).take(30)) {
      try {
        final v = jsonDecode(line);
        if (v is Map) {
          final m = v['payload'] is Map ? v['payload'] as Map : v;
          cwd = m['cwd'] is String ? m['cwd'] as String : cwd;
          if (v['type'] == 'session/title' && v['data'] is Map) {
            title = (v['data'] as Map)['title'] as String? ?? title;
          }
        }
      } catch (_) {}
    }
    final first =
        messages.where((m) => m['role'] == 'user').firstOrNull?['text'] ??
        messages.first['text']!;
    title = title.isEmpty ? first.replaceAll(RegExp(r'\s+'), ' ') : title;
    return ExternalSessionCandidate(
      source,
      file.path,
      title.substring(0, title.length.clamp(0, 100)),
      cwd,
      stat.modified,
      messages,
    );
  }

  Future<List<ExternalSessionCandidate>> discover({
    String workspace = '',
  }) async {
    _candidates.clear();
    _reload.clear();
    if (home.isEmpty) return [];
    final roots = {
      'Claude Code': p.join(home, '.claude', 'projects'),
      'Codex': p.join(home, '.codex', 'sessions'),
      'Grok Build': p.join(home, '.grok', 'sessions'),
      'DeepSeek Harness': p.join(home, '.dsh', 'sessions'),
    };
    for (final entry in roots.entries) {
      final dir = Directory(entry.value);
      if (!await dir.exists()) continue;
      final files = await _recentFiles(dir);
      for (final file in files) {
        try {
          final candidate = await _file(entry.key, file);
          if (candidate == null) continue;
          _candidates[candidate.id] = candidate;
          _reload[candidate.id] = () => _file(entry.key, file);
        } catch (_) {
          /* Unsupported/damaged source is never modified. */
        }
      }
    }
    final dbFile = File(
      p.join(home, '.local', 'share', 'opencode', 'opencode.db'),
    );
    if (await dbFile.exists()) {
      try {
        final db = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
        try {
          for (final row in db.select(
            'SELECT id,title,directory,time_updated FROM session WHERE parent_id IS NULL ORDER BY time_updated DESC LIMIT 8',
          )) {
            final key = row['id'] as String;
            final candidate = _openCode(db, dbFile.path, key, row);
            if (candidate == null) continue;
            _candidates[candidate.id] = candidate;
            _reload[candidate.id] = () async {
              final fresh = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
              try {
                final rows = fresh.select(
                  'SELECT id,title,directory,time_updated FROM session WHERE id=?',
                  [key],
                );
                return rows.isEmpty
                    ? null
                    : _openCode(fresh, dbFile.path, key, rows.first);
              } finally {
                fresh.close();
              }
            };
          }
        } finally {
          db.close();
        }
      } catch (_) {
        /* Keep other compatible sources available. */
      }
    }
    final rows = _candidates.values.toList()
      ..sort((a, b) {
        final sameA = workspace.isNotEmpty && p.equals(a.cwd, workspace),
            sameB = workspace.isNotEmpty && p.equals(b.cwd, workspace);
        if (sameA != sameB) return sameA ? -1 : 1;
        return b.updated.compareTo(a.updated);
      });
    // Each client already has its own bounded scan. A global cutoff can hide
    // every session from a less recently used client in the client picker.
    return rows;
  }

  ExternalSessionCandidate? _openCode(
    Database db,
    String file,
    String id,
    Row meta,
  ) {
    final messages = <Map<String, String>>[];
    for (final row in db.select(
      'SELECT id,data FROM message WHERE session_id=? ORDER BY time_created DESC LIMIT 200',
      [id],
    ).reversed) {
      final data = jsonDecode(row['data'] as String) as Map;
      final role = data['role'];
      if (role != 'user' && role != 'assistant') continue;
      final parts = db.select(
        'SELECT data FROM part WHERE message_id=? ORDER BY time_created',
        [row['id']],
      );
      final text = parts
          .map((p) => jsonDecode(p['data'] as String))
          .whereType<Map>()
          .where((v) => v['type'] == 'text')
          .map((v) => v['text'] as String? ?? '')
          .join('\n');
      if (text.isNotEmpty) messages.add({'role': role as String, 'text': text});
    }
    if (messages.isEmpty) return null;
    return ExternalSessionCandidate(
      'OpenCode',
      '$file#$id',
      meta['title'] as String? ?? id,
      meta['directory'] as String? ?? '',
      DateTime.fromMillisecondsSinceEpoch(meta['time_updated'] as int),
      messages,
    );
  }

  Future<ExternalSessionCandidate> reviewed(
    String id,
    String fingerprint,
  ) async {
    final old = _candidates[id];
    final reload = _reload[id];
    if (old == null || reload == null) throw StateError('候选会话已过期，请刷新');
    final fresh = await reload();
    if (fresh == null || fresh.fingerprint != fingerprint) {
      throw StateError('来源会话已变化，请重新预览后导入');
    }
    return fresh;
  }

  ExternalSessionCandidate candidate(String id) =>
      _candidates[id] ?? (throw StateError('候选会话已过期'));
}
