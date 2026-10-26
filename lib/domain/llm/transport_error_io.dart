import 'dart:io';

bool isTransportFailure(Object? error) =>
    error is SocketException || error is TlsException || error is HttpException;

String underlyingTransportDetails(Object? error) {
  // Never stringify arbitrary exceptions: parser/client errors may contain
  // request or response bodies. OS codes/messages provide useful network data.
  final OSError? osError = error is SocketException
      ? error.osError
      : error is TlsException
      ? error.osError
      : null;
  return [
    error == null ? '底层异常：未提供' : '底层异常：${error.runtimeType}',
    if (osError != null) '系统错误：${osError.errorCode} ${osError.message}',
  ].join('\n');
}

DateTime? retryAfterDate(String value) {
  try {
    return HttpDate.parse(value);
  } catch (_) {
    return DateTime.tryParse(value);
  }
}
