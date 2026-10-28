import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/errors/app_failure.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/domain/llm/model_connection_tester.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:flutter/material.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:expert_chat/platform/preferences.dart';

// Opt-in only: reads the installed application's connection settings, never
// its conversations. RUN_LIVE additionally runs bounded synthetic requests;
// neither mode stores credentials or modifies the application settings.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    const bool.fromEnvironment('EXPERT_CHAT_RUN_LIVE')
        ? 'configured service acceptance'
        : 'read-only acceptance connection inventory',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('验收配置检查'))),
      );
      final result = <String, dynamic>{};
      await tester.runAsync(() async {
        const secure = FlutterSecureStorage();
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('providerProfiles');
        final profiles = raw == null
            ? <ProviderProfile>[]
            : [
                for (final p in jsonDecode(raw) as List)
                  ProviderProfile.fromJson(Map<String, dynamic>.from(p as Map)),
              ];
        final activeId = prefs.getString('activeProfileId');
        final active =
            profiles.where((p) => p.id == activeId).firstOrNull ??
            profiles.firstOrNull;
        final key = active == null
            ? ''
            : await secure.read(key: 'apikey_${active.id}') ?? '';
        result['chat'] = {
          'configured':
              active != null && active.baseUrl.isNotEmpty && key.isNotEmpty,
          'host': active == null ? '' : Uri.tryParse(active.baseUrl)?.host,
          'model': prefs.getString('selectedModel') ?? active?.chatModel,
        };
        final imageRaw = prefs.getString('imageGenerationApi');
        final image = imageRaw == null
            ? const MediaApiConfig()
            : MediaApiConfig.fromJson(
                Map<String, dynamic>.from(jsonDecode(imageRaw) as Map),
              );
        final imageKey = image.baseUrl.isEmpty
            ? ''
            : await secure.read(key: 'image_generation_api_key') ?? '';
        result['image'] = {
          'configured': image.isConfiguredWith(imageKey),
          'host': Uri.tryParse(image.baseUrl)?.host,
          'model': image.model,
        };
        final gatewayRaw = prefs.getString('expertChatGateway');
        final gateway = gatewayRaw == null
            ? const GatewayConfig()
            : GatewayConfig.fromJson(
                Map<String, dynamic>.from(jsonDecode(gatewayRaw) as Map),
              );
        final mcpKey = gateway.baseUrl.isEmpty
            ? ''
            : await secure.read(key: 'expert_chat_gateway_token') ?? '';
        result['document_service'] = {
          'configured':
              gateway.enabled &&
              gateway.baseUrl.isNotEmpty &&
              mcpKey.isNotEmpty,
          'host': Uri.tryParse(gateway.baseUrl)?.host,
          'endpoint': Uri.tryParse(
            gateway.baseUrl,
          )?.replace(userInfo: '', query: '', fragment: '').toString(),
        };
        final directory = Directory(
          const String.fromEnvironment(
            'ACCEPTANCE_REPORT_DIR',
            defaultValue: 'output/acceptance',
          ),
        );
        await directory.create(recursive: true);
        if (const bool.fromEnvironment('EXPERT_CHAT_RUN_LIVE')) {
          final cases = <Map<String, dynamic>>[];
          result['cases'] = cases;
          final chat = active == null || key.isEmpty
              ? null
              : LlmConfig(
                  baseUrl: active.baseUrl,
                  apiKey: key,
                  model: prefs.getString('selectedModel') ?? active.chatModel,
                );
          const scope = String.fromEnvironment(
            'EXPERT_CHAT_LIVE_SCOPE',
            defaultValue: 'all',
          );
          if (!const {'all', 'chat', 'image', 'document'}.contains(scope)) {
            throw ArgumentError.value(scope, 'EXPERT_CHAT_LIVE_SCOPE');
          }
          result['scope'] = scope;
          _knownSecrets = [key, imageKey, mcpKey];
          _progressWriter = () => File(
            '${directory.path}/service-results-$scope.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
          if (scope == 'all' || scope == 'chat') await _chatChecks(cases, chat);
          if (scope == 'all' || scope == 'image') {
            await _imageCheck(cases, image, imageKey, directory);
          }
          if (scope == 'all' || scope == 'document') {
            await _documentChecks(cases, gateway, mcpKey);
          }
        }
        final name = const bool.fromEnvironment('EXPERT_CHAT_RUN_LIVE')
            ? 'service-results-${const String.fromEnvironment('EXPERT_CHAT_LIVE_SCOPE', defaultValue: 'all')}.json'
            : 'connection-inventory.json';
        await File(
          '${directory.path}/$name',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      });
      // Values contain readiness and host/model metadata only, never tokens.
      stdout.writeln('CONNECTION_INVENTORY ${jsonEncode(result)}');
      if (result['cases'] case final List cases) {
        expect(
          cases.every((r) => r['status'] == 'passed'),
          isTrue,
          reason:
              'See the redacted acceptance report for failed or blocked cases.',
        );
      }
    },
    skip: !const bool.fromEnvironment('EXPERT_CHAT_READ_CONNECTIONS'),
  );
}

List<String> _knownSecrets = [];
Future<void> Function()? _progressWriter;
final Map<String, dynamic> _imageTrace = {};

Future<void> _case(
  List<Map<String, dynamic>> results,
  String name,
  Future<Map<String, dynamic>> Function() action,
) async {
  final result = <String, dynamic>{'case': name, 'status': 'running'};
  results.add(result);
  await _progressWriter?.call();
  final clock = Stopwatch()..start();
  try {
    result.addAll({'status': 'passed', ...await action()});
  } catch (e) {
    final failure = AppFailure.from(e, secrets: _knownSecrets);
    result.addAll({
      'status': 'failed',
      'category': failure.kind.name,
      'errorType': e.runtimeType.toString(),
      'detail': failure.details.length > 500
          ? failure.details.substring(0, 500)
          : failure.details,
    });
    if (e is McpClientException) result['code'] = e.code;
    if (e is FormatException) result['offset'] = e.offset;
  }
  result['elapsedMs'] = clock.elapsedMilliseconds;
  if (name == 'single_image_generation') {
    result['responseShape'] = Map.of(_imageTrace);
  }
  await _progressWriter?.call();
}

Future<void> _chatChecks(
  List<Map<String, dynamic>> results,
  LlmConfig? config,
) async {
  if (config == null) {
    results.add({
      'case': 'chat',
      'status': 'blocked',
      'reason': 'not configured',
    });
    return;
  }
  final provider = OpenAiCompatibleProvider(
    responseHeaderTimeout: const Duration(seconds: 15),
  );
  final tester = ModelConnectionTester(provider);
  await _case(results, 'chat_response', () async {
    await tester.check(config, cancelToken: CancelToken());
    return {'replyReceived': true};
  });
  await _case(results, 'chat_invalid_key', () async {
    try {
      await tester.check(
        config.copyWith(apiKey: 'expert-chat-invalid-acceptance-key'),
        cancelToken: CancelToken(),
      );
    } catch (e) {
      final kind = AppFailure.from(e).kind;
      if (kind == FailureKind.authentication ||
          kind == FailureKind.permission) {
        return {'rejection': kind.name};
      }
      rethrow;
    }
    throw StateError('Invalid credential unexpectedly accepted');
  });
  await _case(results, 'chat_local_cancel', () async {
    final token = CancelToken();
    final first = Completer<void>();
    StreamSubscription<ChatChunk>? sub;
    try {
      sub = provider
          .streamChat(
            config: config.copyWith(allowReasoningRetry: false),
            messages: [
              LlmRequestMessage(
                role: MessageRole.user,
                content: '请按编号介绍二十种常见水果，每种两句话。',
              ),
            ],
            thinking: false,
            cancelToken: token,
          )
          .listen(
            (chunk) {
              if (!first.isCompleted &&
                  (chunk.contentDelta?.isNotEmpty ?? false)) {
                first.complete();
              }
            },
            onError: (Object e) {
              if (!first.isCompleted) first.completeError(e);
            },
            onDone: () {
              if (!first.isCompleted) {
                first.completeError(StateError('No response received'));
              }
            },
          );
      await first.future.timeout(const Duration(seconds: 20));
      token.cancel('acceptance cancel');
      await sub.cancel().timeout(const Duration(seconds: 5));
      sub = null;
      return {'cancelledLocally': true, 'remoteCancellationConfirmed': false};
    } finally {
      if (!token.isCancelled) token.cancel('acceptance cleanup');
      if (sub != null) unawaited(sub.cancel());
    }
  });
  await _case(results, 'chat_retry_after_auth_failure', () async {
    await tester.check(config, cancelToken: CancelToken());
    return {'replyReceived': true};
  });
}

Future<void> _imageCheck(
  List<Map<String, dynamic>> results,
  MediaApiConfig config,
  String key,
  Directory directory,
) async {
  if (!config.isConfiguredWith(key)) {
    results.add({
      'case': 'image',
      'status': 'blocked',
      'reason': 'not configured',
    });
    return;
  }
  await _case(results, 'single_image_generation', () async {
    final token = CancelToken();
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 3),
          sendTimeout: const Duration(minutes: 1),
        ),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            _imageTrace['status'] = response.statusCode;
            _imageTrace['contentType'] = response.headers.value('content-type');
            _imageTrace['type'] = response.data.runtimeType.toString();
            if (response.data is String) {
              final safe = redactDiagnostics(
                response.data as String,
                secrets: _knownSecrets,
              );
              _imageTrace['prefix'] = safe.length > 180
                  ? safe.substring(0, 180)
                  : safe;
            }
            if (response.data is Map) {
              _imageTrace['keys'] = (response.data as Map).keys
                  .map((k) => k.toString())
                  .toList();
            }
            handler.next(response);
          },
        ),
      );
      final result = await OpenAiCompatibleMediaProvider(dio: dio)
          .generateImage(
            config: config,
            apiKey: key,
            prompt: '白色背景中央有一个简单的蓝色圆形图标，无文字，无其他元素。',
            cancelToken: token,
          )
          .timeout(
            const Duration(seconds: 180),
            onTimeout: () {
              token.cancel('acceptance image timeout');
              throw TimeoutException('image acceptance timeout');
            },
          );
      if (result.base64 == null) throw StateError('Image bytes not available');
      _imageTrace['base64Length'] = result.base64!.length;
      _imageTrace['base64Prefix'] = result.base64!.length > 32
          ? result.base64!.substring(0, 32)
          : result.base64;
      var encoded = result.base64!.trim();
      if (encoded.startsWith('data:')) {
        encoded = encoded.substring(encoded.indexOf(',') + 1);
      }
      encoded = encoded.replaceAll(RegExp(r'\s'), '');
      final bytes = base64Decode(base64.normalize(encoded));
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = {'width': frame.image.width, 'height': frame.image.height};
      frame.image.dispose();
      codec.dispose();
      final ext = result.mimeType == 'image/jpeg'
          ? 'jpg'
          : result.mimeType == 'image/webp'
          ? 'webp'
          : 'png';
      await File('${directory.path}/live-image.$ext').writeAsBytes(bytes);
      return {'imagesRequested': 1, 'bytes': bytes.length, ...size};
    } finally {
      if (!token.isCancelled) token.cancel('acceptance image finished');
    }
  });
}

Future<void> _documentChecks(
  List<Map<String, dynamic>> results,
  GatewayConfig config,
  String key,
) async {
  if (!config.enabled || config.baseUrl.isEmpty || key.isEmpty) {
    results.add({
      'case': 'document',
      'status': 'blocked',
      'reason': 'not configured',
    });
    return;
  }
  final connection = GatewayConnection(config: config, apiToken: key);
  final client = McpClient(
    dio: Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
      ),
    ),
  );
  final owned = <String>{};
  final uploads = <String>{};
  final stamp = DateTime.now().microsecondsSinceEpoch;
  Future<McpToolResult> call(String name, Map<String, dynamic> args) =>
      client.callTool(connection: connection, name: name, arguments: args);
  try {
    await _case(results, 'document_edit_and_download', () async {
      await client.discover(connection: connection);
      final text = 'acceptance-$stamp before';
      final bytes = utf8.encode(text);
      final begun = await call('begin_upload', {
        'filename': 'acceptance-$stamp.txt',
        'mime_type': 'text/plain',
        'size_bytes': bytes.length,
      });
      final upload = begun.structuredContent['upload_id'] as String;
      uploads.add(upload);
      await call('append_upload', {
        'upload_id': upload,
        'chunk_base64': base64Encode(bytes),
        'offset': 0,
      });
      final finished = await call('finish_upload', {'upload_id': upload});
      uploads.remove(upload);
      final source = finished.structuredContent['file_id'] as String;
      owned.add(source);
      final edited = await call('edit_document', {
        'file_id': source,
        'output_filename': 'acceptance-edited-$stamp.txt',
        'patch': {
          'schema_version': 1,
          'format': 'txt',
          'ops': [
            {'op': 'replace_text', 'find': 'before', 'replace': 'after'},
          ],
        },
      });
      final editedId = edited.structuredContent['file_id'] as String;
      owned.add(editedId);
      final content = await client.readBinaryResource(
        connection: connection,
        uri: 'expert-chat://documents/$editedId/binary',
      );
      if (utf8.decode(content) != 'acceptance-$stamp after') {
        throw StateError('Document output mismatch');
      }
      return {'format': 'txt', 'contentVerified': true};
    });
    await _case(results, 'document_missing_id', () async {
      try {
        await call('inspect_document', {
          'file_id': 'acceptance-missing-$stamp',
        });
      } on McpClientException catch (e) {
        if (e.code != 'tool_error') rethrow;
        return {'missingRejected': true};
      }
      throw StateError('Missing document was accepted');
    });
    await _case(results, 'document_upload_abort', () async {
      final begun = await call('begin_upload', {
        'filename': 'acceptance-abort-$stamp.txt',
        'mime_type': 'text/plain',
        'size_bytes': 4,
      });
      final id = begun.structuredContent['upload_id'] as String;
      uploads.add(id);
      await call('abort_upload', {'upload_id': id});
      uploads.remove(id);
      return {'uploadAborted': true};
    });
  } finally {
    await _case(results, 'document_cleanup', () async {
      for (final id in uploads) {
        await call('abort_upload', {'upload_id': id});
      }
      for (final id in owned) {
        await call('delete_document', {'file_id': id});
      }
      return {
        'documentsRemoved': owned.length,
        'uploadsRemoved': uploads.length,
      };
    });
  }
}
