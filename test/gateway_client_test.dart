import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/gateway/gateway_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('discovers versioned modules through the unified connection', () async {
    final adapter = _GatewayManifestAdapter();
    final client = GatewayClient(dio: Dio()..httpClientAdapter = adapter);
    const connection = GatewayConnection(
      config: GatewayConfig(
        enabled: true,
        baseUrl: 'https://gateway.example.com/',
      ),
      apiToken: 'shared-token',
    );

    final manifest = await client.discover(connection: connection);

    expect(adapter.path, '/v1/capabilities');
    expect(adapter.authorization, 'Bearer shared-token');
    expect(manifest.protocolVersion, 1);
    expect(manifest.gatewayVersion, '0.2.0');
    expect(manifest.supports(GatewayCapabilityIds.longTasks), isTrue);
    expect(manifest.supports(GatewayCapabilityIds.documentEdit), isTrue);
    expect(manifest.metadata(GatewayCapabilityIds.documentEdit)['formats'], [
      'xlsx',
      'docx',
    ]);
  });

  test('discovered capability list is authoritative', () {
    const undiscovered = GatewayConfig(
      enabled: true,
      baseUrl: 'https://gateway.example.com',
    );
    expect(undiscovered.supports(GatewayCapabilityIds.documentEdit), isTrue);

    final discovered = undiscovered.copyWith(
      capabilitiesDiscovered: true,
      capabilities: const [GatewayCapabilityIds.longTasks],
    );
    expect(discovered.supports(GatewayCapabilityIds.longTasks), isTrue);
    expect(discovered.supports(GatewayCapabilityIds.documentEdit), isFalse);
  });

  test('optional upload URL normalizes and survives JSON round trip', () {
    const config = GatewayConfig(
      enabled: true,
      baseUrl: 'https://gateway.example.com/',
      uploadBaseUrl: 'https://upload.example.com///',
    );

    expect(config.normalizedBaseUrl, 'https://gateway.example.com');
    expect(config.normalizedUploadBaseUrl, 'https://upload.example.com');
    expect(config.effectiveUploadBaseUrl, 'https://upload.example.com');
    expect(config.hasDedicatedUploadBaseUrl, isTrue);

    final restored = GatewayConfig.fromJson(config.toJson());
    expect(restored.uploadBaseUrl, config.uploadBaseUrl);
    expect(restored.effectiveUploadBaseUrl, 'https://upload.example.com');

    final legacy = GatewayConfig.fromJson(const {
      'enabled': true,
      'baseUrl': 'https://gateway.example.com',
    });
    expect(legacy.uploadBaseUrl, isEmpty);
    expect(legacy.effectiveUploadBaseUrl, legacy.normalizedBaseUrl);
  });
}

class _GatewayManifestAdapter implements HttpClientAdapter {
  String? path;
  String? authorization;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    path = options.uri.path;
    authorization = options.headers['Authorization']?.toString();
    return ResponseBody.fromString(
      jsonEncode({
        'protocol_version': 1,
        'gateway_version': '0.2.0',
        'capabilities': {
          'long_tasks': {'version': 1},
          'document_edit': {
            'version': 1,
            'formats': ['xlsx', 'docx'],
          },
        },
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
