import 'dart:convert';
import 'dart:io';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';
import 'package:expert_chat/domain/errors/app_failure.dart';

// Explicitly supplied endpoint/token only. Uses synthetic text and cleans up
// only the file/upload IDs returned by this run's own creation requests.
Future<void> main() async {
  final url = Platform.environment['EXPERT_CHAT_MCP_URL'] ?? '';
  final token = Platform.environment['EXPERT_CHAT_MCP_TOKEN'] ?? '';
  final reportPath =
      Platform.environment['EXPERT_CHAT_ACCEPTANCE_REPORT'] ??
      'output/acceptance/local-mcp-results.json';
  if (url.isEmpty || token.isEmpty) {
    stderr.writeln('MCP endpoint and test token are required.');
    exitCode = 2;
    return;
  }
  final client = McpClient();
  final connection = GatewayConnection(
    config: GatewayConfig(
      enabled: true,
      baseUrl: url,
      requestTimeoutSeconds: 20,
    ),
    apiToken: token,
  );
  final results = <Map<String, dynamic>>[];
  final owned = <String>{};
  final uploads = <String>{};
  final nonce = DateTime.now().microsecondsSinceEpoch;
  Future<void> save() async {
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'cases': results,
        'remainingDocuments': owned.toList(),
        'remainingUploads': uploads.toList(),
      }),
    );
  }

  Future<bool> run(String name, Future<void> Function() action) async {
    final row = <String, dynamic>{'case': name, 'status': 'running'};
    results.add(row);
    await save();
    final clock = Stopwatch()..start();
    try {
      await action();
      row['status'] = 'passed';
    } catch (e) {
      row.addAll({
        'status': 'failed',
        'category': AppFailure.from(e).kind.name,
        'detail': redactDiagnostics(e.toString(), secrets: [token]),
      });
    }
    row['elapsedMs'] = clock.elapsedMilliseconds;
    await save();
    return row['status'] == 'passed';
  }

  Future<McpToolResult> call(String name, Map<String, dynamic> args) =>
      client.callTool(connection: connection, name: name, arguments: args);
  String? source;
  try {
    final available = await run('discovery', () async {
      final found = await client.discover(connection: connection);
      if (!found.tools.any((t) => t.name == 'edit_document')) {
        throw StateError('Document tool not available');
      }
    });
    if (available) {
      final uploaded = await run('chunk_upload', () async {
        final bytes = utf8.encode('acceptance-$nonce before');
        final start = await call('begin_upload', {
          'filename': 'acceptance-$nonce.txt',
          'mime_type': 'text/plain',
          'size_bytes': bytes.length,
        });
        final id = start.structuredContent['upload_id'] as String;
        uploads.add(id);
        await save();
        await call('append_upload', {
          'upload_id': id,
          'chunk_base64': base64Encode(bytes),
          'offset': 0,
        });
        final finish = await call('finish_upload', {'upload_id': id});
        source = finish.structuredContent['file_id'] as String;
        owned.add(source!);
        uploads.remove(id);
      });
      if (uploaded) {
        await run('edit_and_resource_download', () async {
          final edited = await call('edit_document', {
            'file_id': source,
            'output_filename': 'acceptance-edited-$nonce.txt',
            'patch': {
              'schema_version': 1,
              'format': 'txt',
              'ops': [
                {'op': 'replace_text', 'find': 'before', 'replace': 'after'},
              ],
            },
          });
          final id = edited.structuredContent['file_id'] as String;
          owned.add(id);
          await save();
          final bytes = await client.readBinaryResource(
            connection: connection,
            uri: 'expert-chat://documents/$id/binary',
          );
          if (utf8.decode(bytes) != 'acceptance-$nonce after') {
            throw StateError('Document output mismatch');
          }
        });
        await run('missing_document_rejected', () async {
          try {
            await call('inspect_document', {
              'file_id': 'acceptance-missing-$nonce',
            });
          } on McpClientException catch (e) {
            if (e.code == 'tool_error') return;
            rethrow;
          }
          throw StateError('Missing document not rejected');
        });
        await run('retry_valid_document', () async {
          await call('inspect_document', {'file_id': source});
        });
      }
      await run('abort_upload', () async {
        final started = await call('begin_upload', {
          'filename': 'acceptance-cancel-$nonce.txt',
          'mime_type': 'text/plain',
          'size_bytes': 4,
        });
        final id = started.structuredContent['upload_id'] as String;
        uploads.add(id);
        await save();
        final aborted = await call('abort_upload', {'upload_id': id});
        if (aborted.structuredContent['deleted'] != true) {
          throw StateError('Upload not deleted');
        }
        try {
          await call('append_upload', {
            'upload_id': id,
            'chunk_base64': base64Encode(utf8.encode('test')),
            'offset': 0,
          });
        } on McpClientException catch (e) {
          if (e.code == 'tool_error') {
            uploads.remove(id);
            return;
          }
          rethrow;
        }
        throw StateError('Aborted upload remained writable');
      });
    }
  } finally {
    var cleaned = true;
    for (final id in uploads.toList()) {
      if (await run('cleanup_upload', () async {
            await call('abort_upload', {'upload_id': id});
            uploads.remove(id);
          }) ==
          false) {
        cleaned = false;
      }
    }
    for (final id in owned.toList()) {
      if (await run('cleanup_document', () async {
            await call('delete_document', {'file_id': id});
            owned.remove(id);
          }) ==
          false) {
        cleaned = false;
      }
    }
    await save();
    stdout.writeln(
      jsonEncode({
        'passed': results.where((r) => r['status'] == 'passed').length,
        'failed': results.where((r) => r['status'] == 'failed').length,
        'cleanupComplete': cleaned && owned.isEmpty && uploads.isEmpty,
      }),
    );
    if (results.any((r) => r['status'] != 'passed')) exitCode = 1;
  }
}
