import '../../data/gateway_config.dart';
import '../llm/llm_provider.dart';
import 'computer_use_policy.dart';
import 'playwright_mcp_preset.dart';

/// Built-in document MCP, selectable per conversation like custom servers.
class McpServerChoice {
  const McpServerChoice({
    required this.id,
    required this.name,
    this.toolsDiscovered = false,
  });

  final String id;
  final String name;
  final bool toolsDiscovered;
}

/// One model-facing MCP tool plus the server that should handle the call.
class RoutedMcpTool {
  const RoutedMcpTool({
    required this.exposedName,
    required this.originalName,
    required this.serverId,
    required this.tool,
  });

  final String exposedName;
  final String originalName;

  /// Null means the built-in Expert Chat document MCP.
  final String? serverId;
  final DiscoveredMcpTool tool;

  bool get isDocumentMcp => serverId == null;
}

/// Which discovered MCP tools the chat model may see.
///
/// Upload chunk tools stay client-internal. Document edit/convert/inspect keep
/// the existing attachment-based adapters, so their raw MCP schemas (file_id)
/// are not sent to the model.
abstract final class McpHostTools {
  static const expertChatServerId = 'expert-chat';

  static const internalNames = {
    'coding_copy_file',
    'coding_delete_file_if_current',
    'begin_upload',
    'append_upload',
    'finish_upload',
    'abort_upload',
  };

  static const clientAdaptedNames = {
    'edit_document',
    'convert_document',
    'inspect_document',
  };

  static const reservedNames = {
    'work_memory_checkpoint',
    'work_memory_recall',
    'work_history',
    'work_integrate_agent_file',
    'coding_artifact_manifest',
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
    'work_run_command',
    'work_deliver_files',
    'web_search',
    'fetch_url',
    'generate_image',
    'analyze_image',
    'coding_workspace_info',
    'coding_list_directory',
    'coding_read_file',
    'coding_write_file',
    'coding_edit_file',
    'coding_create_directory',
    ...internalNames,
    ...clientAdaptedNames,
  };

  static bool isInternal(String name) => internalNames.contains(name);

  static bool isClientAdapted(String name) => clientAdaptedNames.contains(name);

  static List<DiscoveredMcpTool> modelFacing(List<DiscoveredMcpTool> tools) => [
    for (final tool in tools)
      if (tool.name.isNotEmpty &&
          !isInternal(tool.name) &&
          !isClientAdapted(tool.name))
        tool,
  ];

  /// Document MCP tools first, then enabled custom servers in list order.
  ///
  /// Unique names stay unchanged so later servers can be appended without
  /// renaming earlier tools (better prompt-cache hits). Conflicts and
  /// reserved built-in names get `{slug}__{name}`.
  static List<RoutedMcpTool> mergeForModel({
    required List<DiscoveredMcpTool> documentTools,
    required List<CustomMcpServer> customServers,
  }) {
    final used = <String>{...reservedNames};
    final out = <RoutedMcpTool>[];
    for (final tool in documentTools) {
      if (tool.name.isEmpty || isInternal(tool.name)) continue;
      final exposed = _uniqueName(tool.name, 'expert_chat', used);
      used.add(exposed);
      out.add(
        RoutedMcpTool(
          exposedName: exposed,
          originalName: tool.name,
          serverId: null,
          tool: tool,
        ),
      );
    }
    for (final server in customServers) {
      if (!server.enabled || !server.toolsDiscovered) continue;
      for (final tool in server.tools) {
        if (tool.name.isEmpty || isInternal(tool.name)) continue;
        if (server.computerUse &&
            !ComputerUsePolicy.allowedTools.contains(tool.name)) {
          continue;
        }
        final exposed = _uniqueName(tool.name, server.slug, used);
        used.add(exposed);
        out.add(
          RoutedMcpTool(
            exposedName: exposed,
            originalName: tool.name,
            serverId: server.id,
            tool: server.computerUse
                ? ComputerUsePolicy.modelTool(tool, server.allowForeground)
                : server.localProcess?.isPlaywright == true &&
                      tool.name == 'browser_navigate'
                ? DiscoveredMcpTool(
                    name: tool.name,
                    description:
                        '${tool.description}\n${PlaywrightMcpPreset.guidance}',
                    inputSchema: tool.inputSchema,
                  )
                : tool,
          ),
        );
      }
    }
    return out;
  }

  static String _uniqueName(String name, String slug, Set<String> used) {
    if (!used.contains(name)) return name;
    var exposed = '${slug}__$name';
    if (!used.contains(exposed)) return exposed;
    var index = 2;
    while (used.contains(
      '$slug$index'
      '__$name',
    )) {
      index++;
    }
    return '$slug$index'
        '__$name';
  }

  static ToolSpec toSpec(DiscoveredMcpTool tool) => ToolSpec(
    name: tool.name,
    description: tool.description.trim().isEmpty
        ? '调用 MCP Server 工具 ${tool.name}'
        : tool.description,
    parameters: tool.inputSchema.isEmpty
        ? const {'type': 'object', 'properties': <String, dynamic>{}}
        : tool.inputSchema,
  );
}
