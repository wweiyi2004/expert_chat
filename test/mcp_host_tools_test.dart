import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/mcp_host_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('modelFacing hides upload and client-adapted document tools', () {
    const tools = [
      DiscoveredMcpTool(name: 'begin_upload'),
      DiscoveredMcpTool(name: 'edit_document'),
      DiscoveredMcpTool(name: 'list_documents', description: '列出文档'),
      DiscoveredMcpTool(name: 'delete_document'),
    ];
    expect(McpHostTools.modelFacing(tools).map((tool) => tool.name), [
      'list_documents',
      'delete_document',
    ]);
  });

  test('toSpec fills a default schema and description', () {
    const tool = DiscoveredMcpTool(name: 'list_documents');
    final spec = McpHostTools.toSpec(tool);
    expect(spec.name, 'list_documents');
    expect(spec.description, contains('list_documents'));
    expect(spec.parameters['type'], 'object');
  });
}
