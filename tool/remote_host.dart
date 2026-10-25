import 'dart:io';
import 'dart:convert';
import 'package:expert_chat/domain/remote/remote_host.dart';
import 'package:expert_chat/domain/tools/math/math_process.dart';

Future<void> main(List<String> args) async {
  final positional = args.where((arg) => !arg.startsWith('--')).toList();
  final flags = args.where((arg) => arg.startsWith('--')).toSet();
  if (flags.difference({
    '--allow-network',
    '--protected-tunnel',
    '--rotate-pairing',
  }).isNotEmpty) {
    throw ArgumentError('Unknown host flag');
  }
  if (positional.length < 2) {
    stderr.writeln(
      'Usage: dart run tool/remote_host.dart DATA_DIRECTORY WORKSPACE [PORT] [BIND_ADDRESS] [--allow-network]\n'
      'Bearer credential is saved in DATA_DIRECTORY/credential. Keep it private.\n'
      'LAN use requires an existing encrypted VPN/tunnel; HTTP is for loopback/trusted tunnel only.',
    );
    exitCode = 64;
    return;
  }
  final host = RemoteHost(Directory(positional[0]), Directory(positional[1]));
  host.protectedTunnel = args.contains('--protected-tunnel');
  final cert = Platform.environment['EXPERT_REMOTE_TLS_CERT'];
  final key = Platform.environment['EXPERT_REMOTE_TLS_KEY'];
  if ((cert == null) != (key == null)) {
    throw ArgumentError('Both TLS certificate and key are required');
  }
  if (cert != null && key != null) {
    host.tls = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
  }
  host.modelUrl = Platform.environment['EXPERT_REMOTE_MODEL_URL'];
  host.modelName = Platform.environment['EXPERT_REMOTE_MODEL'];
  host.modelKey = Platform.environment['EXPERT_REMOTE_MODEL_KEY'];
  host.modelFormat =
      Platform.environment['EXPERT_REMOTE_MODEL_FORMAT'] ?? 'openAiCompatible';
  final policies =
      (Platform.environment['EXPERT_REMOTE_ALLOWED_POLICIES'] ?? 'request')
          .split(',')
          .map((value) => value.trim())
          .toSet();
  if (policies.difference({'request', 'assisted', 'full'}).isNotEmpty) {
    throw ArgumentError('Unknown allowed execution policy');
  }
  host.allowedPolicies.addAll(policies);
  host.reviewModelUrl = Platform.environment['EXPERT_REMOTE_REVIEW_URL'];
  host.reviewModelName = Platform.environment['EXPERT_REMOTE_REVIEW_MODEL'];
  host.reviewModelKey = Platform.environment['EXPERT_REMOTE_REVIEW_KEY'];
  host.reviewModelFormat = Platform.environment['EXPERT_REMOTE_REVIEW_FORMAT'];
  host.roundCeiling =
      (int.tryParse(
                Platform.environment['EXPERT_REMOTE_ROUND_CEILING'] ?? '',
              ) ??
              200)
          .clamp(1, 1000);
  host.allowAutoBudgetExtension =
      Platform.environment['EXPERT_REMOTE_AUTO_BUDGET'] == 'true';
  host.maxBudgetReviews =
      (int.tryParse(
                Platform.environment['EXPERT_REMOTE_BUDGET_REVIEWS'] ?? '',
              ) ??
              2)
          .clamp(0, 5);
  host.budgetExtensionRounds =
      (int.tryParse(
                Platform.environment['EXPERT_REMOTE_BUDGET_EXTRA_ROUNDS'] ?? '',
              ) ??
              5)
          .clamp(1, 100);
  host.maxRounds =
      (int.tryParse(Platform.environment['EXPERT_REMOTE_MAX_ROUNDS'] ?? '') ??
              20)
          .clamp(1, host.roundCeiling);
  host.commandTimeoutSeconds =
      (int.tryParse(
                Platform.environment['EXPERT_REMOTE_COMMAND_TIMEOUT'] ?? '',
              ) ??
              600)
          .clamp(1, 3600);
  final configuredScript = Platform.environment['EXPERT_REMOTE_MATH_SCRIPT'];
  final executableDirectory = File(Platform.resolvedExecutable).parent;
  final candidates = [
    ?configuredScript,
    '${executableDirectory.path}/assets/math/toolkit.py',
    '${executableDirectory.path}/data/flutter_assets/assets/math/toolkit.py',
    '${File(Platform.script.toFilePath()).parent.parent.path}/assets/math/toolkit.py',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!await file.exists()) continue;
    final script = await file.readAsString();
    host.mathExecutor = (arguments) async => jsonEncode(
      await executeMathScript(
        arguments,
        pythonExecutable:
            Platform.environment['EXPERT_REMOTE_MATH_PYTHON'] ?? 'python',
        trustedScript: script,
        childEnvironment: host.safeToolEnvironment,
      ),
    );
    break;
  }
  await host.open(rotatePairing: args.contains('--rotate-pairing'));
  await host.listen(
    port: positional.length > 2 ? int.parse(positional[2]) : 47831,
    address: positional.length > 3 ? positional[3] : '127.0.0.1',
    allowNetwork: args.contains('--allow-network'),
  );
  stdout.writeln(
    'Expert Chat execution host listening on port ${host.port}. Workspace: ${positional[1]}. Credential: ${positional[0]}/credential',
  );
  // Host lifetime is independent of Flutter. No task is tied to an HTTP client.
}
