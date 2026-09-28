import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/document/document_patch.dart';
import 'package:expert_chat/domain/document/document_service_client.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/tools/document_tool_executor.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart'
    show FakeSettings, FakeLlmProvider, InMemoryRepo, InMemoryLibraryFileStore;

const _connection = GatewayConnection(
  config: GatewayConfig(enabled: true, baseUrl: 'https://document.example'),
  apiToken: 'test-token',
);

Attachment _source({
  String name = 'source.txt',
  String? bytes = 'YmVmb3Jl',
  bool truncated = false,
}) => Attachment(
  name: name,
  mimeType: 'text/plain',
  sizeBytes: 6,
  text: 'before',
  imageBase64: bytes,
  truncated: truncated,
);

ToolCall _editCall({
  String? name,
  String format = 'txt',
  bool setText = false,
}) => ToolCall(
  index: 0,
  id: 'edit-1',
  name: 'edit_document',
  argumentsJson: jsonEncode({
    'attachment_name': ?name,
    'patch': {
      'schema_version': 1,
      'format': format,
      'output_filename': 'edited.$format',
      'ops': [
        if (setText)
          {'op': 'set_text', 'text': 'after'}
        else
          {'op': 'replace_text', 'find': 'before', 'replace': 'after'},
      ],
    },
  }),
);

ToolCall _call(String name, String args) =>
    ToolCall(index: 0, id: 'call-1', name: name, argumentsJson: args);

class _Client extends DocumentServiceClient {
  final requests =
      <
        ({
          String name,
          GatewayConnection connection,
          Map<String, dynamic> args,
          List<int>? bytes,
          CancelToken? token,
        })
      >[];
  Future<({String text, DocumentEditResult? file})> Function() respond =
      () async => (
        text: '',
        file: DocumentEditResult(
          bytes: Uint8List.fromList(utf8.encode('after')),
          filename: 'edited.txt',
          contentType: 'text/plain',
        ),
      );

  @override
  Future<DocumentEditResult> edit({
    required GatewayConnection connection,
    required Uint8List fileBytes,
    required String filename,
    required DocumentPatch patch,
    CancelToken? cancelToken,
  }) async {
    requests.add((
      name: 'edit_document',
      connection: connection,
      args: {'filename': filename, 'patch': patch.toJson()},
      bytes: List.of(fileBytes),
      token: cancelToken,
    ));
    return (await respond()).file!;
  }

  @override
  Future<DocumentEditResult> convert({
    required GatewayConnection connection,
    required Uint8List fileBytes,
    required String filename,
    required String targetFormat,
    String? outputFilename,
    CancelToken? cancelToken,
  }) async {
    requests.add((
      name: 'convert_document',
      connection: connection,
      args: {
        'filename': filename,
        'target_format': targetFormat,
        'output_filename': outputFilename,
      },
      bytes: List.of(fileBytes),
      token: cancelToken,
    ));
    return (await respond()).file!;
  }

  @override
  Future<({String text, DocumentEditResult? file})> callDiscoveredTool({
    required GatewayConnection connection,
    required String name,
    required Map<String, dynamic> arguments,
    CancelToken? cancelToken,
  }) {
    requests.add((
      name: name,
      connection: connection,
      args: arguments,
      bytes: null,
      token: cancelToken,
    ));
    return respond();
  }
}

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    return base.copyWith(
      searchMode: SearchMode.off,
      gateway: base.gateway.copyWith(
        customMcpServers: const [
          CustomMcpServer(
            id: 'one',
            name: 'First',
            baseUrl: 'https://one.example',
            toolsDiscovered: true,
            tools: [DiscoveredMcpTool(name: 'export_file')],
          ),
          CustomMcpServer(
            id: 'two',
            name: 'Second',
            baseUrl: 'https://two.example',
            toolsDiscovered: true,
            tools: [DiscoveredMcpTool(name: 'export_file')],
          ),
        ],
      ),
    );
  }
}

class _DesktopSettings extends _Settings {
  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    return base.copyWith(
      selectedModel: KnownModels.vision,
      gateway: base.gateway.copyWith(
        customMcpServers: const [
          CustomMcpServer(
            id: 'desktop',
            name: 'Desktop',
            baseUrl: 'https://desktop.example',
            computerUse: true,
            toolsDiscovered: true,
            tools: [
              DiscoveredMcpTool(name: 'get_window_state'),
              DiscoveredMcpTool(name: 'click'),
            ],
          ),
        ],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late DocumentToolExecutor executor;
  late List<SearchActivity> activities;
  late List<Attachment> files;
  late List<String> errors;
  late List<String> events;
  late bool active;
  setUp(() {
    client = _Client();
    activities = [];
    files = [];
    errors = [];
    events = [];
    active = true;
    executor = DocumentToolExecutor(
      getClient: () => client,
      isActive: () => active,
      onActivity: (a) {
        activities.add(a);
        events.add(a.status.name);
      },
      onAttachment: (a) {
        files.add(a);
        events.add('file');
      },
      onError: errors.add,
    );
  });

  Future<String> edit({
    ToolCall? call,
    List<Attachment>? sources,
    bool supported = true,
    CancelToken? token,
  }) => executor.edit(
    call ?? _editCall(),
    supported: supported,
    connection: _connection,
    sources: sources ?? [_source()],
    cancelToken: token ?? CancelToken(),
  );

  Future<String> run(String operation, CancelToken token) =>
      switch (operation) {
        'edit' => edit(token: token),
        'convert' => executor.convert(
          _call('convert_document', '{"target_format":"md"}'),
          supported: true,
          connection: _connection,
          sources: [_source()],
          cancelToken: token,
        ),
        _ => executor.callMcp(
          _call('routed_export', '{}'),
          name: 'export',
          connection: _connection,
          cancelToken: token,
        ),
      };

  test(
    'inspect selects named files case insensitively and needs no raw bytes',
    () {
      final result = executor.inspect(
        _call('inspect_document', '{"attachment_name":" SOURCE.TXT "}'),
        sources: [
          _source(name: 'other.md'),
          _source(bytes: null, truncated: true),
        ],
      );
      expect(result, contains('附件：source.txt'));
      expect(result, contains('has_original_bytes: no'));
      expect(result, contains('禁止 set_text'));
      expect(activities.last.items.single.title, 'source.txt');
      expect(client.requests, isEmpty);
      expect(files, isEmpty);
    },
  );

  test(
    'unnamed selection prefers retained bytes and unknown names never fallback',
    () async {
      await edit(
        sources: [
          _source(name: 'missing.txt', bytes: null),
          _source(),
        ],
      );
      expect(client.requests.single.args['filename'], 'source.txt');
      final result = await edit(call: _editCall(name: 'absent.txt'));
      expect(result, contains('找不到附件'));
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'capability denial blocks editing and conversion before client acquisition',
    () async {
      expect(await edit(supported: false), contains('不支持文档编辑'));
      expect(
        await executor.convert(
          _call('convert_document', '{}'),
          supported: false,
          connection: _connection,
          sources: [_source()],
          cancelToken: CancelToken(),
        ),
        contains('不支持格式转换'),
      );
      expect(client.requests, isEmpty);
      expect(
        activities.where((a) => a.status == SearchActivityStatus.failed),
        hasLength(2),
      );
    },
  );

  test(
    'invalid patches, missing bytes, mismatches and corrupt bytes never upload',
    () async {
      expect(await edit(call: _call('edit_document', '[]')), contains('补丁无效'));
      expect(await edit(sources: []), contains('本轮没有可编辑附件'));
      expect(await edit(sources: [_source(bytes: null)]), contains('未保留原始文件'));
      expect(
        await edit(sources: [_source(name: 'source.md')]),
        contains('不一致'),
      );
      expect(await edit(sources: [_source(bytes: '%%%')]), contains('数据损坏'));
      expect(client.requests, isEmpty);
      expect(files, isEmpty);
    },
  );

  test(
    'truncated text rejects full replacement but permits targeted replacement',
    () async {
      expect(
        await edit(
          call: _editCall(setText: true),
          sources: [_source(truncated: true)],
        ),
        contains('禁止使用 set_text'),
      );
      expect(client.requests, isEmpty);
      await edit(sources: [_source(truncated: true)]);
      expect(client.requests.single.bytes, utf8.encode('before'));
    },
  );

  test(
    'editing preserves request bytes and publishes the file before completion',
    () async {
      final token = CancelToken();
      expect(await edit(token: token), contains('已生成修改后的文件「edited.txt」'));
      final request = client.requests.single;
      expect(request.connection, same(_connection));
      expect(request.token, same(token));
      expect(request.bytes, utf8.encode('before'));
      expect((request.args['patch'] as Map)['output_filename'], 'edited.txt');
      expect(utf8.decode(base64Decode(files.single.imageBase64!)), 'after');
      expect(files.single.mimeType, 'text/plain');
      expect(files.single.sizeBytes, 5);
      expect(events.sublist(events.length - 2), ['file', 'done']);
      expect(activities.first.id, activities.last.id);
    },
  );

  test('conversion validates targets and preserves output filename', () async {
    Future<String> convert(String args) => executor.convert(
      _call('convert_document', args),
      supported: true,
      connection: _connection,
      sources: [_source()],
      cancelToken: CancelToken(),
    );
    expect(
      await convert('{"target_format":"pptx"}'),
      contains('不支持 txt → pptx'),
    );
    expect(await convert('{broken'), contains('转换参数无效'));
    expect(client.requests, isEmpty);
    await convert('{"target_format":"md","output_filename":"notes.md"}');
    expect(client.requests.single.args['target_format'], 'md');
    expect(client.requests.single.args['output_filename'], 'notes.md');
    expect(client.requests.single.bytes, utf8.encode('before'));
    expect(files.single.text, contains('格式转换'));
  });

  test(
    'MCP rejects invalid JSON objects and treats blank arguments as empty',
    () async {
      Future<String> mcp(String args) => executor.callMcp(
        _call('alias', args),
        name: 'original',
        connection: _connection,
        cancelToken: CancelToken(),
      );
      expect(await mcp('[]'), contains('参数必须是对象'));
      expect(await mcp('null'), contains('参数必须是对象'));
      expect(await mcp('{'), contains('不是合法 JSON'));
      expect(client.requests, isEmpty);
      await mcp('  ');
      expect(client.requests.single.args, isEmpty);
      expect(client.requests.single.name, 'original');
      expect(activities.last.query, 'alias');
    },
  );

  test(
    'MCP supports text, files, combined results and empty successful results',
    () async {
      for (final hasFile in [false, true]) {
        for (final hasText in [false, true]) {
          client.respond = () async => (
            text: hasText ? '  tool text  ' : '',
            file: hasFile
                ? DocumentEditResult(
                    bytes: Uint8List.fromList([1, 2]),
                    filename: 'export.bin',
                    contentType: 'application/octet-stream',
                  )
                : null,
          );
          final result = await run('mcp', CancelToken());
          expect(
            result,
            hasText ? 'tool text' : contains(hasFile ? 'export.bin' : '无文本结果'),
          );
          expect(activities.last.status, SearchActivityStatus.done);
          expect(activities.last.resultCount, 1);
        }
      }
      expect(files, hasLength(2));
    },
  );

  for (final operation in ['edit', 'convert', 'mcp']) {
    test('$operation cancelled before dispatch makes no request', () async {
      expect(await run(operation, CancelToken()..cancel()), contains('已取消'));
      expect(client.requests, isEmpty);
      expect(files, isEmpty);
    });
    for (final tokenCancelled in [false, true]) {
      test(
        '$operation discards late files when ${tokenCancelled ? 'token cancelled' : 'inactive'}',
        () async {
          final token = CancelToken();
          final response = client.respond;
          client.respond = () async {
            if (tokenCancelled) {
              token.cancel();
            } else {
              active = false;
            }
            return response();
          };
          expect(await run(operation, token), contains('已取消'));
          expect(files, isEmpty);
          expect(errors, isEmpty);
          expect(activities.last.status, SearchActivityStatus.failed);
        },
      );
    }
    test(
      '$operation reports service failure once and suppresses cancelled errors',
      () async {
        client.respond = () async =>
            throw const DocumentServiceException('offline');
        expect(await run(operation, CancelToken()), contains('失败：offline'));
        expect(client.requests, hasLength(1));
        expect(errors, ['offline']);
        final token = CancelToken();
        client.respond = () async {
          token.cancel();
          throw const DocumentServiceException('wrapped cancellation');
        };
        expect(await run(operation, token), contains('已取消'));
        expect(errors, ['offline']);
        expect(client.requests, hasLength(2));
      },
    );
  }

  group('controller integration', () {
    Future<ProviderContainer> setup(
      FakeLlmProvider llm, {
      SettingsController Function() settingsBuilder = _Settings.new,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sharedPrefsProvider.overrideWithValue(prefs),
          libraryFileStoreProvider.overrideWithValue(
            InMemoryLibraryFileStore(),
          ),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          settingsControllerProvider.overrideWith(settingsBuilder),
          llmProvider.overrideWithValue(llm),
          documentServiceClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);
      return container;
    }

    FakeLlmProvider llmFor(ToolCall call) => FakeLlmProvider(
      const [],
      scriptedChunks: [
        [
          ChatChunk(toolCalls: [call]),
        ],
        [const ChatChunk(contentDelta: '完成')],
      ],
    );

    test(
      'desktop workflow feeds fresh screenshots to the next model round',
      () async {
        client.respond = () async => (
          text: 'Current window observation',
          file: DocumentEditResult(
            bytes: base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=',
            ),
            filename: 'screen.png',
            contentType: 'image/png',
          ),
        );
        final llm = FakeLlmProvider(
          const [],
          scriptedChunks: [
            [
              ChatChunk(
                toolCalls: [
                  _call('get_window_state', '{"pid":123,"window_id":456}'),
                ],
              ),
            ],
            [
              ChatChunk(
                toolCalls: [
                  _call(
                    'click',
                    '{"pid":123,"window_id":456,"element_token":"snapshot:0"}',
                  ),
                ],
              ),
            ],
            [const ChatChunk(contentDelta: '已核验完成')],
          ],
        );
        final c = await setup(llm, settingsBuilder: _DesktopSettings.new);
        final ctrl = c.read(chatControllerProvider.notifier);
        ctrl.newConversation();
        ctrl.setWorkMode(true);
        ctrl.setCustomMcpServerIds(['desktop']);
        await ctrl.sendMessage('在测试窗口完成操作');
        expect(client.requests.map((r) => r.name), [
          'get_window_state',
          'click',
        ]);
        expect(
          llm.calls[1].where(
            (m) => m.isToolImageObservation && m.hasImageParts,
          ),
          hasLength(1),
        );
        expect(
          llm.calls[2].where(
            (m) => m.isToolImageObservation && m.hasImageParts,
          ),
          hasLength(1),
        );
        expect(llm.calls[2].any((m) => m.content.contains('旧截图已移出')), isTrue);
        expect(
          c
              .read(chatControllerProvider)
              .requireValue
              .current!
              .activePath
              .last
              .content,
          '已核验完成',
        );
      },
    );

    test('ordinary chat does not expose desktop tools', () async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: '你好')]);
      final c = await setup(llm, settingsBuilder: _DesktopSettings.new);
      final ctrl = c.read(chatControllerProvider.notifier);
      ctrl.newConversation();
      ctrl.setCustomMcpServerIds(['desktop']);
      await ctrl.sendMessage('你好');
      expect(client.requests, isEmpty);
      expect(
        llm.toolCalls
            .expand((tools) => tools ?? <ToolSpec>[])
            .any((t) => t.name == 'click'),
        isFalse,
      );
    });

    test(
      'failed document steps retain diagnostics and cannot be replayed by retry',
      () async {
        client.respond = () async =>
            throw const DocumentServiceException('offline');
        final llm = llmFor(_editCall());
        final c = await setup(llm);
        final ctrl = c.read(chatControllerProvider.notifier);
        await ctrl.sendMessage('修改文件', attachments: [_source()]);
        final origin = c.read(chatControllerProvider).requireValue.current!;
        final failed = origin.activePath.last;
        final step = failed.searchActivities.single;
        expect(step.toolName, 'edit_document');
        expect(step.canRetry, isFalse);
        expect(step.resultText, contains('offline'));
        expect(client.requests, hasLength(1));
        client.respond = () async => (
          text: '',
          file: DocumentEditResult(
            bytes: Uint8List.fromList(utf8.encode('after')),
            filename: 'edited.txt',
            contentType: 'text/plain',
          ),
        );
        await ctrl.retryTaskStep(origin.id, failed.id, step.id);
        final current = c.read(chatControllerProvider).requireValue.current!;
        expect(current.activePath.last.id, failed.id);
        expect(current.activePath.last.attachments, isEmpty);
        expect(client.requests, hasLength(1));
        expect(client.requests.single.bytes, utf8.encode('before'));
        expect(llm.callCount, 2);
      },
    );

    for (final stop in [false, true]) {
      test(
        'document results remain with origin when switching conversations (stop=$stop)',
        () async {
          final entered = Completer<void>();
          final released = Completer<void>();
          final respond = client.respond;
          client.respond = () async {
            entered.complete();
            await released.future;
            return respond();
          };
          final c = await setup(llmFor(_editCall()));
          final ctrl = c.read(chatControllerProvider.notifier);
          final sending = ctrl.sendMessage('修改文件', attachments: [_source()]);
          await entered.future;
          final originId = c
              .read(chatControllerProvider)
              .requireValue
              .currentId;
          ctrl.newConversation();
          final nextId = c.read(chatControllerProvider).requireValue.currentId;
          if (stop) ctrl.stop();
          released.complete();
          await sending;
          final state = c.read(chatControllerProvider).requireValue;
          expect(state.currentId, nextId);
          expect(state.current!.messages, isEmpty);
          final answer = state.conversations
              .firstWhere((c) => c.id == originId)
              .activePath
              .last;
          expect(answer.attachments, hasLength(stop ? 0 : 1));
          expect(client.requests, hasLength(1));
        },
      );
    }

    test(
      'MCP aliases route to the original name and matching server',
      () async {
        final settings = await _Settings().build();
        final tool = settings.routedMcpTools.firstWhere(
          (t) =>
              settings.connectionForRouted(t).config.baseUrl ==
              'https://two.example',
        );
        final llm = llmFor(_call(tool.exposedName, '{"format":"txt"}'));
        final c = await setup(llm);
        final ctrl = c.read(chatControllerProvider.notifier);
        ctrl.setCustomMcpServerIds(['one', 'two']);
        await ctrl.sendMessage('导出文件');
        expect(
          llm.toolCalls.first!.map((t) => t.name),
          contains(tool.exposedName),
        );
        expect(client.requests.single.name, 'export_file');
        expect(
          client.requests.single.connection.config.baseUrl,
          'https://two.example',
        );
        expect(client.requests.single.args, {'format': 'txt'});
        final answer = c
            .read(chatControllerProvider)
            .requireValue
            .current!
            .activePath
            .last;
        expect(answer.attachments.single.name, 'edited.txt');
        expect(answer.searchActivities.single.toolName, tool.exposedName);
        expect(answer.searchActivities.single.resultText, contains('已返回文件'));
      },
    );

    test(
      'inspection and conversion preserve tool replies and completion records',
      () async {
        final llm = FakeLlmProvider(
          const [],
          scriptedChunks: [
            [
              ChatChunk(toolCalls: [_call('inspect_document', '{}')]),
            ],
            [
              ChatChunk(
                toolCalls: [
                  _call('convert_document', '{"target_format":"md"}'),
                ],
              ),
            ],
            [const ChatChunk(contentDelta: '已转换')],
          ],
        );
        final c = await setup(llm);
        await c
            .read(chatControllerProvider.notifier)
            .sendMessage('检查并转换文件', attachments: [_source()]);
        expect(client.requests.single.name, 'convert_document');
        final answer = c
            .read(chatControllerProvider)
            .requireValue
            .current!
            .activePath
            .last;
        expect(answer.searchActivities.map((s) => s.toolName), [
          'inspect_document',
          'convert_document',
        ]);
        expect(
          answer.searchActivities.every(
            (s) => s.status == SearchActivityStatus.done,
          ),
          isTrue,
        );
        expect(
          answer.searchActivities.first.resultText,
          contains('text_preview:\nbefore'),
        );
        expect(
          answer.searchActivities.last.resultText,
          contains('已将「source.txt」转换'),
        );
        expect(
          llm.calls.last.where((m) => m.role == MessageRole.tool),
          hasLength(2),
        );
        expect(answer.attachments.single.name, 'edited.txt');
      },
    );

    test(
      'failed MCP calls keep diagnostics without enabling step replay',
      () async {
        final settings = await _Settings().build();
        final tool = settings.routedMcpTools.last;
        client.respond = () async =>
            throw const DocumentServiceException('offline');
        final c = await setup(llmFor(_call(tool.exposedName, '{}')));
        final ctrl = c.read(chatControllerProvider.notifier);
        ctrl.setCustomMcpServerIds(['one', 'two']);
        await ctrl.sendMessage('导出文件');
        final convo = c.read(chatControllerProvider).requireValue.current!;
        final answer = convo.activePath.last;
        final step = answer.searchActivities.single;
        expect(step.status, SearchActivityStatus.failed);
        expect(step.resultText, contains('offline'));
        expect(step.canRetry, isFalse);
        await ctrl.retryTaskStep(convo.id, answer.id, step.id);
        expect(client.requests, hasLength(1));
        expect(
          c
              .read(chatControllerProvider)
              .requireValue
              .current!
              .activePath
              .last
              .id,
          answer.id,
        );
      },
    );
  });
}
