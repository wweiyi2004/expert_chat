enum PtyErrorDomain { posix, win32, hresult, internal }

enum PtyErrorKind {
  invalidArgument,
  notFound,
  permissionDenied,
  spawnFailed,
  workingDirectoryFailed,
  io,
  closed,
  unsupported,
  outOfMemory,
  internal,
}

final class PtyNativeError {
  const PtyNativeError({
    required this.domain,
    required this.kind,
    required this.code,
    required this.message,
  });

  final PtyErrorDomain domain;
  final PtyErrorKind kind;
  final int code;
  final String message;
}

sealed class PtyException implements Exception {
  const PtyException(this.message, {this.nativeError});

  final String message;
  final PtyNativeError? nativeError;

  @override
  String toString() => '$runtimeType: $message';
}

final class PtySpawnException extends PtyException {
  const PtySpawnException(super.message, {super.nativeError});
}

final class PtyIoException extends PtyException {
  const PtyIoException(super.message, {super.nativeError});
}

final class PtyClosedException extends PtyException {
  const PtyClosedException() : super('PTY session is closed');
}

final class PtyUnsupportedException extends PtyException {
  const PtyUnsupportedException(super.message);
}
