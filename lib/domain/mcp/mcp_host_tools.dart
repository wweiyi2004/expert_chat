import '../../data/gateway_config.dart';
import '../llm/llm_provider.dart';

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
    'web_search',
    'fetch_url',
    'generate_image',
    'analyze_image',
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
      if (tool.name.isEmpty) continue;
      used.add(tool.name);
      out.add(
        RoutedMcpTool(
          exposedName: tool.name,
          originalName: tool.name,
          serverId: null,
          tool: tool,
        ),
      );
    }
    for (final server in customServers) {
      if (!server.enabled || !server.toolsDiscovered) continue;
      for (final tool in server.tools) {
        if (tool.name.isEmpty) continue;
        final exposed = _uniqueName(tool.name, server.slug, used);
        used.add(exposed);
        out.add(
          RoutedMcpTool(
            exposedName: exposed,
            originalName: tool.name,
            serverId: server.id,
            tool: tool,
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
