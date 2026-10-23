import 'dart:async';
import 'package:expert_chat/domain/research/research_files.dart';
import 'package:expert_chat/state/research_files_controller.dart';
import 'package:expert_chat/state/research_terminal_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Files implements ResearchFiles {
  final lists = <String, Completer<List<ResearchRemoteFile>>>{};
  final transferring = Completer<void>();
  final release = Completer<void>();
  ResearchTransferToken? token;
  @override
  Future<String> absolute(String path) async => path;
  @override
  Future<List<ResearchRemoteFile>> list(String path) =>
      (lists[path] ??= Completer<List<ResearchRemoteFile>>()).future;
  @override
  Future<String> readText(String path) async => 'text';
  @override
  Future<void> saveText(
    String path,
    String content, {
    required String original,
  }) async {}
  @override
  Future<void> mkdir(String path) async {}
  @override
  Future<void> download(
    String remote,
    String local, {
    required ResearchTransferToken token,
    required void Function(int, int) progress,
  }) async {
    this.token = token;
    progress(4, 10);
    transferring.complete();
    await release.future;
    token.check();
    progress(10, 10);
  }

  @override
  Future<void> upload(
    String local,
    String remote, {
    required ResearchTransferToken token,
    required void Function(int, int) progress,
  }) => download(remote, local, token: token, progress: progress);
}

class _Terminal extends ResearchTerminalController {
  _Terminal(this.remote);
  final _Files remote;
  @override
  ResearchTerminalState build() => const ResearchTerminalState(
    activeProfileId: 'host-a',
    status: ResearchConnectionStatus.connected,
    connectionGeneration: 1,
  );
  @override
  ResearchFiles get files => remote;
}

void main() {
  test('late directory results cannot replace the newest selection', () async {
    final files = _Files();
    final container = ProviderContainer(
      overrides: [
        researchTerminalProvider.overrideWith(() => _Terminal(files)),
      ],
    );
    addTearDown(container.dispose);
    final ctrl = container.read(researchFilesProvider.notifier);
    final first = ctrl.load('/a');
    await Future<void>.delayed(Duration.zero);
    final second = ctrl.load('/b');
    await Future<void>.delayed(Duration.zero);
    files.lists['/b']!.complete([
      const ResearchRemoteFile(name: 'b', path: '/b/b', directory: false),
    ]);
    await second;
    files.lists['/a']!.complete([]);
    await first;
    expect(container.read(researchFilesProvider).directory, '/b');
    expect(container.read(researchFilesProvider).entries.single.name, 'b');
  });
  test(
    'transfer keeps running without a widget subscription and can be cancelled',
    () async {
      final files = _Files();
      final container = ProviderContainer(
        overrides: [
          researchTerminalProvider.overrideWith(() => _Terminal(files)),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(researchFilesProvider, (_, _) {});
      final ctrl = container.read(researchFilesProvider.notifier);
      final transfer = ctrl.transfer(
        local: 'local',
        remote: '/remote',
        upload: false,
      );
      final failure = expectLater(transfer, throwsStateError);
      await files.transferring.future;
      subscription.close();
      await container.pump();
      final job = container.read(researchFilesProvider).transfers.single;
      expect(job.status, ResearchTransferStatus.running);
      expect(files.token!.cancelled, false);
      ctrl.cancel(job.id);
      files.release.complete();
      await failure;
      expect(
        container.read(researchFilesProvider).transfers.single.status,
        ResearchTransferStatus.cancelled,
      );
    },
  );
}
