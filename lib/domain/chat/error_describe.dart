import 'package:dio/dio.dart' show CancelToken, DioException;

/// True when [e] is a cancellation raised by stop() firing the CancelToken.
bool isCancelError(Object e) =>
    e is DioException && CancelToken.isCancel(e);

/// Error-banner text for a caught throwable.
///
/// `Exception`s carry messages written for users, so the message survives as
/// written - only the bare `Exception: ` prefix that `toString()` bolts on is
/// dropped. An `Error` is always a bug and often stringifies to something
/// with no diagnostic value at all - `StackOverflowError` is literally
/// "Stack Overflow", which cost a full debugging session to trace back to a
/// regexp - so those get their type appended.
String describeError(Object e) {
  final text = e.toString();
  if (text.startsWith('Exception: ')) return text.substring(11);
  return e is Exception ? text : '$text（${e.runtimeType}）';
}
