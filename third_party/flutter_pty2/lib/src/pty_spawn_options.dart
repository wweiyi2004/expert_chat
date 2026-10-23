import 'package:flutter_pty2/src/pty_environment.dart';
import 'package:flutter_pty2/src/pty_size.dart';

final class PtySpawnOptions {
  const PtySpawnOptions({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const PtyEnvironment.inherit(),
    this.size = const PtySize(columns: 80, rows: 24),
    this.inputBufferBytes = 1024 * 1024,
    this.outputWindowBytes = 256 * 1024,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final PtyEnvironment environment;
  final PtySize size;

  /// Maximum native queued input and admitted Dart-side asynchronous input.
  final int inputBufferBytes;

  /// Maximum native output that may be outstanding before reading pauses.
  final int outputWindowBytes;

  void validate() {
    if (executable.isEmpty) {
      throw ArgumentError.value(executable, 'executable', 'cannot be empty');
    }
    if (executable.contains('\x00')) {
      throw ArgumentError.value(
        executable,
        'executable',
        'cannot contain NUL bytes',
      );
    }
    for (final argument in arguments) {
      if (argument.contains('\x00')) {
        throw ArgumentError.value(
          argument,
          'arguments',
          'cannot contain NUL bytes',
        );
      }
    }
    if (workingDirectory?.contains('\x00') ?? false) {
      throw ArgumentError.value(
        workingDirectory,
        'workingDirectory',
        'cannot contain NUL bytes',
      );
    }
    size.validate();
    environment.validate();
    if (inputBufferBytes < 64 * 1024) {
      throw ArgumentError.value(
        inputBufferBytes,
        'inputBufferBytes',
        'must be at least 65536 bytes',
      );
    }
    if (outputWindowBytes < 16 * 1024) {
      throw ArgumentError.value(
        outputWindowBytes,
        'outputWindowBytes',
        'must be at least 16384 bytes',
      );
    }
  }
}
