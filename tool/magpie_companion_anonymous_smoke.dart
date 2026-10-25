import 'dart:convert';
import 'dart:io';
import 'package:expert_chat/domain/llm/magpie_companion_io.dart';

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError(
      'Provide the already verified official CLI executable path',
    );
  }
  final directory = await Directory.systemTemp.createTemp(
    'expert-magpie-anonymous-',
  );
  final companion = MagpieCompanion();
  try {
    final models = await companion.start(
      executable: File(arguments.single).absolute.path,
      directory: directory.path,
      apiPort: await freePort(),
      webPort: await freePort(),
    );
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'upstream': 'yetone/magpie',
        'version': 'v0.1.1353',
        'owned_pid_ports_verified': true,
        'anonymous_models': models.length,
        'account_discovery_disabled': true,
        'telemetry_disabled': true,
        'management_not_opened': true,
        'configuration':
            'temporary XDG directory; no login or user credential files inspected',
      }),
    );
  } finally {
    await companion.stopOwned();
    await directory.delete(recursive: true);
  }
}
