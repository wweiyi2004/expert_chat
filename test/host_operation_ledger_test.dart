import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:expert_chat/domain/host/operation_ledger.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';

void main() {
  late Directory directory;
  late File file;
  late HostOperationLedger ledger;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('expert-ledger-test-');
    file = File('${directory.path}/operations.jsonl');
    ledger = await HostOperationLedger.open(file);
  });
  tearDown(() async {
    await ledger.close();
    for (final entry in await directory.list().toList()) {
      await entry.delete();
    }
    await directory.delete();
  });
  test(
    'admission is durable before a side effect and duplicate calls share one result',
    () async {
      var effects = 0;
      final gate = Completer<void>();
      Future<Map<String, Object?>> action() async {
        expect(await file.readAsString(), contains('admitted'));
        effects++;
        await gate.future;
        return {'accepted': true};
      }

      final first = ledger.execute('client/request', 'write', {
        'api_key': 'SYNTHETIC_SECRET_NEVER_LOGGED',
      }, action);
      final duplicate = ledger.execute('client/request', 'write', {
        'api_key': 'SYNTHETIC_SECRET_NEVER_LOGGED',
      }, action);
      gate.complete();
      expect(await first, await duplicate);
      expect(effects, 1);
      expect(
        await file.readAsString(),
        isNot(contains('SYNTHETIC_SECRET_NEVER_LOGGED')),
      );
      expect(
        () => ledger.execute('client/request', 'write', {
          'different': true,
        }, action),
        throwsA(isA<BridgeFailure>().having((e) => e.code, 'code', 'conflict')),
      );
    },
  );
  test('restart never replays a completed or uncertain mutation', () async {
    var effects = 0;
    await ledger.execute('one', 'write', {}, () async {
      effects++;
      return {'value': 'private-result'};
    });
    await ledger.close();
    ledger = await HostOperationLedger.open(file);
    expect(
      () => ledger.execute('one', 'write', {}, () async {
        effects++;
        return {};
      }),
      throwsA(
        isA<BridgeFailure>().having((e) => e.code, 'code', 'unknown_result'),
      ),
    );
    expect(effects, 1);
    expect(await file.readAsString(), isNot(contains('private-result')));
  });
  test(
    'torn final record is preserved and earlier admission remains authoritative',
    () async {
      await ledger.execute('one', 'write', {}, () async => {'accepted': true});
      await ledger.close();
      await file.writeAsString(
        '{"key":"partial',
        mode: FileMode.append,
        flush: true,
      );
      ledger = await HostOperationLedger.open(file);
      expect(
        await directory
            .list()
            .where((f) => f.path.contains('.interrupted-'))
            .length,
        1,
      );
      expect(
        () => ledger.execute('one', 'write', {}, () async => {}),
        throwsA(isA<BridgeFailure>()),
      );
    },
  );
}
