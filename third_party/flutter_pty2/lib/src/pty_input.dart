import 'dart:convert';
import 'dart:typed_data';

enum PtyWriteResult { accepted, backpressured, closed }

abstract interface class PtyInput {
  /// Writes all [data] in order.
  ///
  /// The future waits for input admission and for the native PTY to accept
  /// every byte. Callers should not mutate [data] while a write is pending.
  Future<void> write(Uint8List data);

  /// Attempts to admit one native-sized write without waiting.
  PtyWriteResult tryWrite(Uint8List data);

  /// Waits for writes submitted before this call to complete.
  Future<void> flush();
}

extension PtyInputTextExtension on PtyInput {
  Future<void> writeUtf8(String text) {
    return write(Uint8List.fromList(utf8.encode(text)));
  }
}
