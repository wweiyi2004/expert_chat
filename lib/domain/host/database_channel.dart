import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:stream_channel/stream_channel.dart';

/// Preserve Drift's binary cells while keeping its transport private and bounded.
StreamChannel<Object?> databaseChannel(
  WebSocket socket, {
  void Function()? onClosed,
}) {
  Object? encode(Object? value) => switch (value) {
    Uint8List bytes => {'bytes': base64Encode(bytes)},
    List values => values.map(encode).toList(),
    _ => value,
  };
  Object? decode(Object? value) => switch (value) {
    Map map when map.length == 1 && map['bytes'] is String => base64Decode(
      map['bytes'] as String,
    ),
    List values => values.map(decode).toList(),
    _ => value,
  };
  final outgoing = StreamController<Object?>();
  var notified = false;
  void notifyClosed() {
    if (notified) return;
    notified = true;
    onClosed?.call();
  }

  void closeTransport([int? code]) {
    notifyClosed();
    unawaited(socket.close(code).then<void>((_) {}, onError: (Object _) {}));
  }

  outgoing.stream.listen(
    (value) {
      final encoded = jsonEncode(encode(value));
      if (encoded.length > 160 * 1024 * 1024) {
        closeTransport(WebSocketStatus.messageTooBig);
      } else if (socket.readyState == WebSocket.open) {
        try {
          socket.add(encoded);
        } catch (_) {
          // readyState can still be open after close() has closed its sink.
          // Closing the transport rejects pending Drift requests; never replay.
          closeTransport();
        }
      } else {
        closeTransport();
      }
    },
    onDone: closeTransport,
    onError: (Object _) {
      closeTransport();
    },
  );
  final incoming = socket
      .transform<dynamic>(
        StreamTransformer.fromHandlers(
          handleDone: (sink) {
            notifyClosed();
            sink.close();
          },
        ),
      )
      .map<Object?>((value) {
        if (value is! String || value.length > 160 * 1024 * 1024) {
          throw const FormatException('Invalid database frame');
        }
        return decode(jsonDecode(value));
      });
  return StreamChannel<Object?>(incoming, outgoing.sink);
}
