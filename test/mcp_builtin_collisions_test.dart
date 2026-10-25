import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/mcp_host_tools.dart';

void main() {
  test('configured document gateway also cannot shadow builtins', () {
    final routes = McpHostTools.mergeForModel(
      documentTools: const [
        DiscoveredMcpTool(name: 'math_calculate'),
        DiscoveredMcpTool(name: 'work_spawn_agent'),
        DiscoveredMcpTool(name: 'ordinary_document_tool'),
        DiscoveredMcpTool(name: 'coding_copy_file'),
        DiscoveredMcpTool(name: 'coding_delete_file_if_current'),
      ],
      customServers: [],
    );
    expect(routes.map((route) => route.exposedName), [
      'expert_chat__math_calculate',
      'expert_chat__work_spawn_agent',
      'ordinary_document_tool',
    ]);
    expect(routes.map((route) => route.originalName), [
      'math_calculate',
      'work_spawn_agent',
      'ordinary_document_tool',
    ]);
    expect(routes.every((route) => route.serverId == null), true);
  });
  test(
    'external MCP cannot shadow work, memory, file, role, registry or device builtins',
    () {
      const names = [
        'work_memory_checkpoint',
        'work_memory_recall',
        'work_history',
        'work_integrate_agent_file',
        'coding_artifact_manifest',
        'coding_copy_file',
        'coding_delete_file_if_current',
        'device_observe',
        'device_action',
        'work_ask_user',
        'work_spawn_agent',
        'work_list_agents',
        'work_followup_agent',
        'work_cancel_agent',
        'work_start_process',
        'work_list_processes',
        'work_process_status',
        'work_stop_process',
        'work_restart_process',
        'math_calculate',
        'role_library_search',
        'role_propose',
        'tool_registry_search',
        'tool_registry_request',
      ];
      final routes = McpHostTools.mergeForModel(
        documentTools: [],
        customServers: [
          CustomMcpServer(
            id: 'external',
            name: 'External',
            baseUrl: 'https://example.invalid',
            toolsDiscovered: true,
            tools: [for (final name in names) DiscoveredMcpTool(name: name)],
          ),
        ],
      );
      expect(routes, hasLength(names.length - 2));
      expect(
        routes.any(
          (route) => {
            'coding_copy_file',
            'coding_delete_file_if_current',
          }.contains(route.originalName),
        ),
        false,
      );
      for (final route in routes) {
        expect(route.exposedName, 'external__${route.originalName}');
        expect(route.serverId, 'external');
      }
    },
  );
}
