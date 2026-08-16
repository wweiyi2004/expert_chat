import 'dart:async';
import 'dart:io';

import 'package:expert_chat/domain/tools/pinned_page_client_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startConnectPinned tries each InternetAddress, never the list', () async {
    final seen = <Object?>[];
    final task = await IOOverrides.runZoned(
      () => startConnectPinned(
        addresses: [
          InternetAddress('1.2.3.4'),
          InternetAddress('5.6.7.8'),
        ],
        port: 443,
        host: 'example.com',
      ),
      socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) {
        seen.add(host);
        expect(host, isA<InternetAddress>());
        expect(port, 443);
        if ((host as InternetAddress).address == '1.2.3.4') {
          return Future<ConnectionTask<Socket>>.error(
            const SocketException('unreachable'),
          );
        }
        return Future<ConnectionTask<Socket>>.value(
          ConnectionTask.fromSocket(Completer<Socket>().future, () {}),
        );
      },
    );

    expect(seen, hasLength(2));
    expect((seen[0] as InternetAddress).address, '1.2.3.4');
    expect((seen[1] as InternetAddress).address, '5.6.7.8');
    expect(task, isA<ConnectionTask<Socket>>());
  });

  test('startConnectPinned surfaces the last connection error', () async {
    await expectLater(
      IOOverrides.runZoned(
        () => startConnectPinned(
          addresses: [InternetAddress('1.2.3.4')],
          port: 80,
          host: 'example.com',
        ),
        socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) {
          expect(host, isA<InternetAddress>());
          return Future<ConnectionTask<Socket>>.error(
            const SocketException('refused'),
          );
        },
      ),
      throwsA(
        isA<SocketException>().having(
          (error) => error.message,
          'message',
          'refused',
        ),
      ),
    );
  });
}
