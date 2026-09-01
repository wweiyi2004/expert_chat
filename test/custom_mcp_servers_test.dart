import 'dart:convert';

import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/mcp/mcp_host_tools.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('factory gateway has no custom MCP servers', () {
    const config = GatewayConfig();
    expect(config.customMcpServers, isEmpty);
  });

  test('custom MCP servers round-trip through GatewayConfig JSON', () {
    const server = CustomMcpServer(
      id: 'srv-1',
      name: 'GitHub',
      baseUrl: 'https://mcp.github.example/mcp',
      enabled: true,
      toolsDiscovered: true,
      serverVersion: '1.2.0',
      tools: [
        DiscoveredMcpTool(
          name: 'search',
          description: 'search code',
          inputSchema: {
            'type': 'object',
            'properties': {'q': 'string'},
          },
        ),
      ],
    );
    final encoded = GatewayConfig(customMcpServers: [server]).toJson();
    final decoded = GatewayConfig.fromJson(encoded);
    expect(decoded.customMcpServers, hasLength(1));
    final loaded = decoded.customMcpServers.single;
    expect(loaded.id, 'srv-1');
    expect(loaded.name, 'GitHub');
    expect(loaded.baseUrl, 'https://mcp.github.example/mcp');
    expect(loaded.enabled, isTrue);
    expect(loaded.toolsDiscovered, isTrue);
    expect(loaded.serverVersion, '1.2.0');
    expect(loaded.tools.single.name, 'search');
    expect(loaded.tools.single.description, 'search code');
    expect(loaded.tools.single.inputSchema['properties'], {'q': 'string'});
  });

  test('legacy gateway JSON without custom servers still loads', () {
    final decoded = GatewayConfig.fromJson({
      'enabled': true,
      'baseUrl': 'http://127.0.0.1:8790',
      'mcpTools': [
        {'name': 'list_documents'},
      ],
    });
    expect(decoded.customMcpServers, isEmpty);
    expect(decoded.mcpTools.single.name, 'list_documents');
  });

  test('merge keeps unique custom names and prefixes conflicts', () {
    const document = [DiscoveredMcpTool(name: 'list_documents')];
    const servers = [
      CustomMcpServer(
        id: 'a',
        name: 'Alpha',
        baseUrl: 'https://a.example',
        toolsDiscovered: true,
        tools: [
          DiscoveredMcpTool(name: 'search'),
          DiscoveredMcpTool(name: 'list_documents'),
        ],
      ),
      CustomMcpServer(
        id: 'b',
        name: 'Beta',
        baseUrl: 'https://b.example',
        toolsDiscovered: true,
        tools: [DiscoveredMcpTool(name: 'search')],
      ),
    ];
    final merged = McpHostTools.mergeForModel(
      documentTools: document,
      customServers: servers,
    );
    expect(
      [for (final tool in merged) tool.exposedName],
      ['list_documents', 'search', 'alpha__list_documents', 'beta__search'],
    );
    expect(merged[1].originalName, 'search');
    expect(merged[1].serverId, 'a');
    expect(merged[2].originalName, 'list_documents');
    expect(merged[2].serverId, 'a');
    expect(merged[3].serverId, 'b');
  });

  test('merge prefixes reserved built-in tool names', () {
    const servers = [
      CustomMcpServer(
        id: 'docs',
        name: 'Other Docs',
        baseUrl: 'https://docs.example',
        toolsDiscovered: true,
        tools: [DiscoveredMcpTool(name: 'edit_document')],
      ),
    ];
    final merged = McpHostTools.mergeForModel(
      documentTools: const [],
      customServers: servers,
    );
    expect(merged.single.exposedName, 'other_docs__edit_document');
    expect(merged.single.originalName, 'edit_document');
  });

  test(
    'disabled or undiscovered custom servers stay out of the model list',
    () {
      const servers = [
        CustomMcpServer(
          id: 'off',
          name: 'Off',
          baseUrl: 'https://off.example',
          enabled: false,
          toolsDiscovered: true,
          tools: [DiscoveredMcpTool(name: 'hidden')],
        ),
        CustomMcpServer(
          id: 'pending',
          name: 'Pending',
          baseUrl: 'https://pending.example',
          tools: [DiscoveredMcpTool(name: 'not_ready')],
        ),
      ];
      expect(
        McpHostTools.mergeForModel(
          documentTools: const [],
          customServers: servers,
        ),
        isEmpty,
      );
    },
  );

  test('appending a custom server does not rename earlier unique tools', () {
    const first = CustomMcpServer(
      id: 'a',
      name: 'Alpha',
      baseUrl: 'https://a.example',
      toolsDiscovered: true,
      tools: [DiscoveredMcpTool(name: 'search')],
    );
    const second = CustomMcpServer(
      id: 'c',
      name: 'Gamma',
      baseUrl: 'https://c.example',
      toolsDiscovered: true,
      tools: [DiscoveredMcpTool(name: 'whois')],
    );
    final before = McpHostTools.mergeForModel(
      documentTools: const [DiscoveredMcpTool(name: 'list_documents')],
      customServers: const [first],
    );
    final after = McpHostTools.mergeForModel(
      documentTools: const [DiscoveredMcpTool(name: 'list_documents')],
      customServers: const [first, second],
    );
    expect(
      [for (final tool in before) tool.exposedName],
      ['list_documents', 'search'],
    );
    expect(
      [for (final tool in after) tool.exposedName],
      ['list_documents', 'search', 'whois'],
    );
  });

  test('settings persist custom MCP servers and tokens', () async {
    SharedPreferences.setMockInitialValues({});
    final secureData = <String, String>{};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      secureData,
    );
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });

    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);

    await container.read(settingsControllerProvider.future);
    final controller = container.read(settingsControllerProvider.notifier);
    await controller.addCustomMcpServer(
      id: 'srv-persist',
      name: 'GitHub',
      baseUrl: 'https://mcp.github.example',
      token: 'secret-token',
    );
    await controller.setCustomMcpDiscovered(
      'srv-persist',
      tools: const [DiscoveredMcpTool(name: 'search')],
      serverVersion: '9',
    );

    final encoded = jsonDecode(prefs.getString('expertChatGateway')!) as Map;
    expect(encoded['customMcpServers'], isNotEmpty);
    expect(secureData[customMcpTokenStorageKey('srv-persist')], 'secret-token');

    final reloaded = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(reloaded.dispose);
    final state = await reloaded.read(settingsControllerProvider.future);
    expect(state.gateway.customMcpServers, hasLength(1));
    expect(state.gateway.customMcpServers.single.tools.single.name, 'search');
    expect(state.customMcpTokens['srv-persist'], 'secret-token');
    expect(state.modelMcpTools.map((tool) => tool.name), ['search']);
  });

  test('conversation MCP selection round-trips through JSON', () {
    final conversation = Conversation(
      id: 'c1',
      customMcpServerIds: const ['expert-chat', 'srv-1'],
    );
    final restored = Conversation.fromJson(conversation.toJson());
    expect(restored.customMcpServerIds, ['expert-chat', 'srv-1']);
    expect(
      Conversation.fromJson(const {'id': 'legacy'}).customMcpServerIds,
      isEmpty,
    );
  });

  test(
    'chat only sees MCP tools from servers selected on the conversation',
    () {
      const github = CustomMcpServer(
        id: 'github',
        name: 'GitHub',
        baseUrl: 'https://github.example',
        toolsDiscovered: true,
        tools: [DiscoveredMcpTool(name: 'search')],
      );
      const docs = CustomMcpServer(
        id: 'docs',
        name: 'Docs',
        baseUrl: 'https://docs.example',
        toolsDiscovered: true,
        tools: [DiscoveredMcpTool(name: 'lookup')],
      );
      const settings = SettingsState(
        gateway: GatewayConfig(
          enabled: true,
          baseUrl: 'http://127.0.0.1:8790',
          capabilitiesDiscovered: true,
          mcpTools: [DiscoveredMcpTool(name: 'list_documents')],
          customMcpServers: [github, docs],
        ),
      );

      expect(settings.availableMcpServers.map((choice) => choice.id), [
        McpHostTools.expertChatServerId,
        'github',
        'docs',
      ]);
      expect(
        settings.modelMcpToolsFor(const ['github']).map((tool) => tool.name),
        ['search'],
      );
      expect(settings.modelMcpToolsFor(const []), isEmpty);
      expect(
        settings
            .modelMcpToolsFor(const [McpHostTools.expertChatServerId, 'docs'])
            .map((tool) => tool.name),
        ['list_documents', 'lookup'],
      );
    },
  );

  test('persists per-conversation MCP selection in Drift', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = DriftConversationRepository(db);
    final timestamp = DateTime.utc(2026, 8, 31);
    await repo.saveConversation(
      Conversation(
        id: 'mcp-convo',
        title: 'MCP chat',
        customMcpServerIds: const ['expert-chat', 'github'],
        updatedAt: timestamp,
      ),
    );
    final loaded = await repo.loadConversation('mcp-convo');
    expect(loaded.customMcpServerIds, ['expert-chat', 'github']);
    final summaries = await repo.loadSummaries();
    expect(summaries.single.customMcpServerIds, ['expert-chat', 'github']);
  });
}
