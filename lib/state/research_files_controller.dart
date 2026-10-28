import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';
import '../domain/research/research_files.dart';
import 'research_terminal_controller.dart';

enum ResearchTransferStatus { running, done, failed, cancelled }

class ResearchTransfer {
  const ResearchTransfer({
    required this.id,
    required this.profileId,
    required this.local,
    required this.remote,
    required this.upload,
    this.bytes = 0,
    this.total = -1,
    this.error,
    this.status = ResearchTransferStatus.running,
  });
  final String id, profileId, local, remote;
  final bool upload;
  final int bytes, total;
  final String? error;
  final ResearchTransferStatus status;
  ResearchTransfer copy({
    int? bytes,
    int? total,
    String? error,
    ResearchTransferStatus? status,
  }) => ResearchTransfer(
    id: id,
    profileId: profileId,
    local: local,
    remote: remote,
    upload: upload,
    bytes: bytes ?? this.bytes,
    total: total ?? this.total,
    error: error,
    status: status ?? this.status,
  );
}

class ResearchFilesState {
  const ResearchFilesState({
    this.directory = '.',
    this.entries = const [],
    this.loading = false,
    this.error,
    this.transfers = const [],
  });
  final String directory;
  final List<ResearchRemoteFile> entries;
  final bool loading;
  final String? error;
  final List<ResearchTransfer> transfers;
  ResearchFilesState copy({
    String? directory,
    List<ResearchRemoteFile>? entries,
    bool? loading,
    String? error,
    List<ResearchTransfer>? transfers,
  }) => ResearchFilesState(
    directory: directory ?? this.directory,
    entries: entries ?? this.entries,
    loading: loading ?? this.loading,
    error: error,
    transfers: transfers ?? this.transfers,
  );
}

final researchFilesProvider =
    NotifierProvider<ResearchFilesController, ResearchFilesState>(
      ResearchFilesController.new,
    );

class ResearchFilesController extends Notifier<ResearchFilesState> {
  int _browseRevision = 0;
  final _tokens = <String, ResearchTransferToken>{};
  @override
  ResearchFilesState build() {
    ref.onDispose(() {
      for (final token in _tokens.values) {
        token.cancelled = true;
      }
    });
    ref.listen(researchTerminalProvider.select((s) => s.connectionGeneration), (
      _,
      next,
    ) {
      _browseRevision++;
      for (final token in _tokens.values) {
        token.cancelled = true;
      }
      state = state.copy(directory: '.', entries: [], loading: false);
      if (ref.read(researchTerminalProvider).isConnected) {
        Future.microtask(() {
          if (ref.mounted) load('.');
        });
      }
    });
    return const ResearchFilesState();
  }

  Future<void> load([String? path]) async {
    final revision = ++_browseRevision;
    state = state.copy(loading: true);
    try {
      final files = ref.read(researchTerminalProvider.notifier).files;
      final absolute = await files.absolute(path ?? state.directory);
      final entries = await files.list(absolute);
      if (!ref.mounted || revision != _browseRevision) return;
      state = state.copy(directory: absolute, entries: entries, loading: false);
    } catch (e) {
      if (ref.mounted && revision == _browseRevision) {
        state = state.copy(loading: false, error: '$e');
      }
    }
  }

  void cancel(String id) {
    _tokens[id]?.cancelled = true;
  }

  void _update(ResearchTransfer job) {
    if (!ref.mounted) return;
    state = state.copy(
      transfers: [
        for (final t in state.transfers)
          if (t.id == job.id) job else t,
      ],
    );
  }

  Future<void> transfer({
    required String local,
    required String remote,
    required bool upload,
  }) async {
    final terminal = ref.read(researchTerminalProvider);
    final files = ref.read(researchTerminalProvider.notifier).files;
    if (_tokens.length >= 3) throw StateError('已有 3 个传输任务，请稍后再试');
    var job = ResearchTransfer(
      id: const Uuid().v4(),
      profileId: terminal.activeProfileId ?? '',
      local: local,
      remote: remote,
      upload: upload,
    );
    final token = ResearchTransferToken();
    _tokens[job.id] = token;
    state = state.copy(transfers: [job, ...state.transfers].take(50).toList());
    final watch = Stopwatch()..start();
    var lastPublish = 0;
    void progress(int bytes, int total) {
      job = job.copy(bytes: bytes, total: total);
      if (watch.elapsedMilliseconds - lastPublish >= 100 || bytes == total) {
        lastPublish = watch.elapsedMilliseconds;
        _update(job);
      }
    }

    try {
      if (upload) {
        await files.upload(local, remote, token: token, progress: progress);
      } else {
        await files.download(remote, local, token: token, progress: progress);
      }
      _update(job.copy(status: ResearchTransferStatus.done));
      if (ref.mounted &&
          upload &&
          ref.read(researchTerminalProvider).connectionGeneration ==
              terminal.connectionGeneration) {
        await load();
      }
    } catch (e) {
      _update(
        job.copy(
          status: token.cancelled
              ? ResearchTransferStatus.cancelled
              : ResearchTransferStatus.failed,
          error: '$e',
        ),
      );
      rethrow;
    } finally {
      _tokens.remove(job.id);
    }
  }

  Future<void> retry(ResearchTransfer job) {
    if (ref.read(researchTerminalProvider).activeProfileId != job.profileId) {
      throw StateError('请先连接原主机再重试');
    }
    return transfer(local: job.local, remote: job.remote, upload: job.upload);
  }
}
