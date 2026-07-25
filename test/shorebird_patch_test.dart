import 'package:expert_chat/domain/update/shorebird_patch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

void main() {
  test('reports a non-Shorebird build as unsupported', () async {
    final updater = _FakeShorebirdUpdater(
      isAvailable: false,
      status: UpdateStatus.unavailable,
    );

    final result = await ShorebirdPatchService(updater: updater).check();

    expect(result.unsupported, isTrue);
    expect(result.failed, isFalse);
    expect(updater.checkCalls, 0);
  });

  test('restartRequired does not download the same patch again', () async {
    final updater = _FakeShorebirdUpdater(
      status: UpdateStatus.restartRequired,
      current: const Patch(number: 2),
      next: const Patch(number: 3),
    );

    final result = await ShorebirdPatchService(updater: updater).check();

    expect(result.restartRequired, isTrue);
    expect(result.downloaded, isFalse);
    expect(updater.updateCalls, 0);
    expect(result.message, contains('重新打开'));
  });

  test('outdated downloads once and marks restart required', () async {
    final updater = _FakeShorebirdUpdater(
      status: UpdateStatus.outdated,
      current: const Patch(number: 2),
    );

    final result = await ShorebirdPatchService(updater: updater).check();

    expect(result.available, isTrue);
    expect(result.downloaded, isTrue);
    expect(result.restartRequired, isTrue);
    expect(updater.updateCalls, 1);
  });

  test('download false only reports availability', () async {
    final updater = _FakeShorebirdUpdater(status: UpdateStatus.outdated);

    final result = await ShorebirdPatchService(
      updater: updater,
    ).check(download: false);

    expect(result.available, isTrue);
    expect(result.downloaded, isFalse);
    expect(result.restartRequired, isFalse);
    expect(updater.updateCalls, 0);
  });

  test('network/check errors are failures, not unsupported builds', () async {
    final updater = _FakeShorebirdUpdater(
      status: UpdateStatus.upToDate,
      checkError: StateError('offline'),
    );

    final result = await ShorebirdPatchService(updater: updater).check();

    expect(result.failed, isTrue);
    expect(result.unsupported, isFalse);
    expect(result.message, contains('offline'));
  });
}

class _FakeShorebirdUpdater implements ShorebirdUpdater {
  _FakeShorebirdUpdater({
    this.isAvailable = true,
    required this.status,
    this.current,
    this.next,
    this.checkError,
  });

  @override
  final bool isAvailable;
  final UpdateStatus status;
  final Patch? current;
  final Patch? next;
  final Object? checkError;
  int checkCalls = 0;
  int updateCalls = 0;

  @override
  Future<UpdateStatus> checkForUpdate({UpdateTrack? track}) async {
    checkCalls++;
    if (checkError case final error?) throw error;
    return status;
  }

  @override
  Future<Patch?> readCurrentPatch() async => current;

  @override
  Future<Patch?> readNextPatch() async => next;

  @override
  Future<void> update({UpdateTrack? track}) async {
    updateCalls++;
  }
}
