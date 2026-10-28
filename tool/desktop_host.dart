import 'dart:io';
import 'package:expert_chat/domain/host/desktop_host.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(
      'expert-host [--data-dir DIR] [--discovery-dir DIR] [--workspace-cli EXE] [--gui-client-pid PID] [--idle-seconds N (0 disables)]',
    );
    return;
  }
  if (args.contains('--version')) {
    stdout.writeln('Expert Host 1 / Dart');
    return;
  }
  for (var i = 0; i < args.length; i += 2) {
    if (!{
          '--data-dir',
          '--discovery-dir',
          '--workspace-cli',
          '--gui-client-pid',
          '--idle-seconds',
        }.contains(args[i]) ||
        i + 1 >= args.length) {
      stderr.writeln('Unknown or incomplete host option; use --help.');
      exitCode = 64;
      return;
    }
  }
  String? option(String name) {
    final index = args.indexOf(name);
    if (index < 0) return null;
    if (index + 1 >= args.length) throw ArgumentError('Missing $name value');
    return args[index + 1];
  }

  final idle = int.tryParse(option('--idle-seconds') ?? '600');
  if (idle == null || idle < 0 || idle > 86400) {
    stderr.writeln('idle-seconds must be 0–86400');
    exitCode = 64;
    return;
  }
  final host = DesktopHost(
    dataDirectory:
        option('--data-dir') ?? Platform.environment['EXPERT_HOST_DATA_DIR'],
    discoveryDirectory:
        option('--discovery-dir') ??
        Platform.environment['EXPERT_HOST_DISCOVERY'],
    workspaceExecutable: option('--workspace-cli'),
    guiClientPid: int.tryParse(option('--gui-client-pid') ?? ''),
    idleTimeout: Duration(seconds: idle),
  );
  try {
    await host.start();
    stdout.writeln(
      'Expert Host ready on loopback port ${host.port}; credentials remain in private discovery storage.',
    );
    final signal = ProcessSignal.sigint.watch().listen(
      (_) async => host.close(),
    );
    await host.done;
    await signal.cancel();
  } catch (error) {
    stderr.writeln(
      'Expert Host failed (${error.runtimeType}); original data retained. Check data ownership, storage and bundle compatibility.',
    );
    exitCode = 1;
  }
}
