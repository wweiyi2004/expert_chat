import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/document/document_patch.dart';
import 'package:expert_chat/domain/document/document_service_client.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';

Future<void> main() async {
  final url = Platform.environment['EXPERT_CHAT_MCP_URL']?.trim() ??
      'http://127.0.0.1:8790';
  final token = Platform.environment['EXPERT_CHAT_MCP_TOKEN']?.trim() ?? '';
  if (token.isEmpty) {
    stderr.writeln('请设置 EXPERT_CHAT_MCP_TOKEN。');
    exitCode = 2;
    return;
  }
  final connection = GatewayConnection(
    config: GatewayConfig(
      enabled: true,
      baseUrl: url,
      capabilitiesDiscovered: true,
      capabilities: const [
        GatewayCapabilityIds.documentEdit,
        GatewayCapabilityIds.documentConvert,
      ],
    ),
    apiToken: token,
  );
  final server = await McpClient().discover(connection: connection);
  stdout.writeln(
    'MCP ${server.name} ${server.version}: '
    '${server.tools.map((tool) => tool.name).join(', ')}',
  );

  final result = await DocumentServiceClient().edit(
    connection: connection,
    fileBytes: Uint8List.fromList(utf8.encode('before')),
    filename: 'smoke.txt',
    patch: DocumentPatch.parse({
      'schema_version': 1,
      'format': 'txt',
      'output_filename': 'smoke-edited.txt',
      'ops': [
        {
          'op': 'replace_text',
          'find': 'before',
          'replace': 'after',
        },
      ],
    }),
  );
  if (utf8.decode(result.bytes) != 'after') {
    throw StateError('MCP 文档回读内容不匹配。');
  }
  stdout.writeln('MCP 文档链路通过：${result.filename}');
}
