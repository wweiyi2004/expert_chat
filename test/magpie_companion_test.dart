import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/magpie_companion.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  final fixture = File(
    'output/test-fixtures/magpie-companion-fixture.exe',
  ).absolute;
  test(
    'owned companion fixed environment, port ownership, account launch and model routing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'expert-magpie-contract-',
      );
      final companion = MagpieCompanion();
      final api = await freePort(), web = await freePort();
      addTearDown(() async {
        await companion.stopOwned();
        await directory.delete(recursive: true);
      });
      expect(
        await companion.start(
          executable: fixture.path,
          directory: directory.path,
          apiPort: api,
          webPort: web,
        ),
        ['fixture/provider-model'],
      );
      expect(companion.owned, true);
      final audit =
          jsonDecode(
                await File(
                  '${directory.path}/config/fixture-audit.json',
                ).readAsString(),
              )
              as Map;
      expect(audit['accountDiscovery'], false);
      expect(audit['telemetry'], false);
      expect(audit['apiHost'], '127.0.0.1');
      expect(audit['webHost'], '127.0.0.1');
      await companion.openManagement((uri) async {
        expect(uri.host, '127.0.0.1');
        expect(uri.port, web);
        expect(uri.queryParameters['k'], isNotEmpty);
        return true;
      });
      final chunks = await OpenAiCompatibleProvider()
          .streamChat(
            config: LlmConfig(
              baseUrl: 'http://127.0.0.1:$api/v1',
              apiKey: 'magpie',
              model: 'fixture/provider-model',
            ),
            messages: [],
          )
          .toList();
      expect(
        chunks.map((chunk) => chunk.contentDelta ?? '').join(),
        'companion model fixture',
      );
      await companion.stopOwned();
      expect(companion.owned, false);
    },
    skip: !Platform.isWindows || !fixture.existsSync()
        ? 'Run dart compile exe test/fixtures/magpie_companion_fixture.dart -o output/test-fixtures/magpie-companion-fixture.exe first'
        : false,
  );
  test(
    'occupied listener is never hijacked or stopped',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'expert-magpie-conflict-',
      );
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final companion = MagpieCompanion();
      addTearDown(() async {
        await companion.stopOwned();
        await occupied.close();
        await directory.delete(recursive: true);
      });
      await expectLater(
        companion.start(
          executable: fixture.path,
          directory: directory.path,
          apiPort: occupied.port,
          webPort: await freePort(),
        ),
        throwsStateError,
      );
      expect(companion.owned, false);
      expect(occupied.port, greaterThan(0));
    },
    skip: !Platform.isWindows || !fixture.existsSync(),
  );
}
