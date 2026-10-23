import 'dart:typed_data';

import 'package:flutter_pty2/src/pty_exception.dart';
import 'package:flutter_pty2/src/pty_exit.dart';

sealed class NativeEvent {
  const NativeEvent();

  factory NativeEvent.parse(Object? message) {
    if (message is! List<Object?> || message.isEmpty) {
      throw const FormatException('Native event must be a non-empty list');
    }
    final eventType = _readInt(message, 0);
    return switch (eventType) {
      1 => _parseSpawned(message),
      2 => _parseSpawnFailed(message),
      3 => _parseOutput(message),
      4 => _parseOutputClosed(message),
      5 => _parseWriteComplete(message),
      6 => _parseWritable(message),
      7 => _parseInputClosed(message),
      8 => _parseProcessExit(message),
      9 => _parseAsyncError(message),
      10 => _parseSessionClosed(message),
      _ => throw FormatException('Unknown native event type: $eventType'),
    };
  }
}

NativeEvent _parseSpawned(List<Object?> message) {
  _expectLength(message, 3);
  return NativeSpawned(
    pid: _readInt(message, 1),
    capabilities: _readInt(message, 2),
  );
}

NativeEvent _parseSpawnFailed(List<Object?> message) {
  _expectLength(message, 5);
  return NativeSpawnFailed(_readError(message, 1));
}

NativeEvent _parseOutput(List<Object?> message) {
  _expectLength(message, 2);
  return NativeOutput(_readBytes(message, 1));
}

NativeEvent _parseOutputClosed(List<Object?> message) {
  _expectLength(message, 1);
  return const NativeOutputClosed();
}

NativeEvent _parseWriteComplete(List<Object?> message) {
  _expectLength(message, 2);
  return NativeWriteComplete(_readInt(message, 1));
}

NativeEvent _parseWritable(List<Object?> message) {
  _expectLength(message, 1);
  return const NativeWritable();
}

NativeEvent _parseInputClosed(List<Object?> message) {
  _expectLength(message, 5);
  return NativeInputClosed(_readError(message, 1));
}

NativeEvent _parseProcessExit(List<Object?> message) {
  _expectLength(message, 3);
  return NativeProcessExit(exit: _readExit(message, 1));
}

NativeEvent _parseAsyncError(List<Object?> message) {
  _expectLength(message, 5);
  return NativeAsyncError(_readError(message, 1));
}

NativeEvent _parseSessionClosed(List<Object?> message) {
  _expectLength(message, 1);
  return const NativeSessionClosed();
}

final class NativeSpawned extends NativeEvent {
  const NativeSpawned({required this.pid, required this.capabilities});

  final int pid;
  final int capabilities;
}

final class NativeSpawnFailed extends NativeEvent {
  const NativeSpawnFailed(this.error);

  final PtyNativeError error;
}

final class NativeOutput extends NativeEvent {
  const NativeOutput(this.bytes);

  final Uint8List bytes;
}

final class NativeOutputClosed extends NativeEvent {
  const NativeOutputClosed();
}

final class NativeWriteComplete extends NativeEvent {
  const NativeWriteComplete(this.requestId);

  final int requestId;
}

final class NativeWritable extends NativeEvent {
  const NativeWritable();
}

final class NativeInputClosed extends NativeEvent {
  const NativeInputClosed(this.error);

  final PtyNativeError error;
}

final class NativeProcessExit extends NativeEvent {
  const NativeProcessExit({required this.exit});

  final PtyExit exit;
}

final class NativeAsyncError extends NativeEvent {
  const NativeAsyncError(this.error);

  final PtyNativeError error;
}

final class NativeSessionClosed extends NativeEvent {
  const NativeSessionClosed();
}

int _readInt(List<Object?> message, int index) {
  if (index >= message.length) {
    throw FormatException(
      'Native event field $index is missing from ${message.length}-field '
      'event (${message.toString()})',
    );
  }
  if (message[index] case final int value) return value;
  throw FormatException(
    'Native event field $index must be an integer; '
    'got ${message[index].runtimeType} (${message[index]})',
  );
}

Uint8List _readBytes(List<Object?> message, int index) {
  if (index >= message.length) {
    throw FormatException('Native event field $index must be Uint8List');
  }
  if (message[index] case final Uint8List bytes) return bytes;
  throw FormatException('Native event field $index must be Uint8List');
}

void _expectLength(List<Object?> message, int expected) {
  if (message.length == expected) return;
  throw FormatException(
    'Native event type ${message[0]} must contain exactly $expected fields; '
    'got ${message.length}',
  );
}

PtyNativeError _readError(List<Object?> message, int index) {
  final domain = _readInt(message, index);
  final kind = _readInt(message, index + 1);
  final code = _readInt(message, index + 2);
  final messageText = switch (message.length > index + 3) {
    true => message[index + 3],
    false => null,
  };
  if (messageText case final String text) {
    return PtyNativeError(
      domain: _enumValue(PtyErrorDomain.values, domain, 'error domain'),
      kind: _enumValue(PtyErrorKind.values, kind, 'error kind'),
      code: code,
      message: text,
    );
  }
  throw const FormatException('Native error message must be a string');
}

PtyExit _readExit(List<Object?> message, int index) {
  final kind = _readInt(message, index);
  final value = _readInt(message, index + 1);
  return switch (kind) {
    0 => PtyExitCode(value),
    1 => PtySignalExit(value),
    _ => throw FormatException('Unknown process exit kind: $kind'),
  };
}

T _enumValue<T>(List<T> values, int index, String name) {
  if (index <= 0 || index > values.length) {
    throw FormatException('Unknown $name: $index');
  }
  return values[index - 1];
}
