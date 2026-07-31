import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../data/media_api_config.dart';
import '../media/openai_compatible_media_provider.dart';
import 'speech_input_service.dart';

/// Small adapter around [AudioRecorder] so cloud-ASR lifecycle logic can be
/// tested without a platform microphone.
abstract interface class SpeechAudioRecorder {
  Future<bool> hasPermission();

  Future<void> start(String path);

  Future<String?> stop();

  Future<void> cancel();

  Future<void> dispose();
}

class WavSpeechAudioRecorder implements SpeechAudioRecorder {
  WavSpeechAudioRecorder({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start(String path) => _recorder.start(
    const RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
    ),
    path: path,
  );

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Records a WAV clip locally, then submits it to MiMo ASR.
///
/// This is intentionally separate from [SystemSpeechInputService]: it needs
/// raw microphone audio, whereas system speech recognition exposes only a
/// platform-provided transcript. It emits the same callback types so the chat
/// composer can swap implementations without changing its draft behavior.
class MimoSpeechInputService {
  MimoSpeechInputService({
    required this.mediaProvider,
    SpeechAudioRecorder? recorder,
    Future<Directory> Function()? temporaryDirectory,
    Duration maxRecordingDuration = _defaultMaxRecordingDuration,
    int maxRecordingFileBytes = _defaultMaxRecordingFileBytes,
  }) : _recorder = recorder ?? WavSpeechAudioRecorder(),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       // The fields are private so the service interface stays stable while
       // the named parameters stay public for tests.
       // ignore: prefer_initializing_formals
       _maxRecordingDuration = maxRecordingDuration,
       // ignore: prefer_initializing_formals
       _maxRecordingFileBytes = maxRecordingFileBytes;

  final OpenAiCompatibleMediaProvider mediaProvider;
  final SpeechAudioRecorder _recorder;
  final Future<Directory> Function() _temporaryDirectory;

  /// Cap for a single recording, matching the 90s fallback of the system
  /// speech path so both ASR routes behave alike.
  static const Duration _defaultMaxRecordingDuration = Duration(seconds: 90);

  /// Cap for a recording file. Larger clips are rejected before they are
  /// read into memory (16 kHz mono WAV ≈ 1.9 MB per minute).
  static const int _defaultMaxRecordingFileBytes = 25 * 1024 * 1024;

  final Duration _maxRecordingDuration;
  final int _maxRecordingFileBytes;

  SpeechInputResultCallback? _resultCallback;
  SpeechInputStatusCallback? _statusCallback;
  SpeechInputErrorCallback? _errorCallback;
  CancelToken? _cancelToken;
  File? _recordingFile;
  Timer? _recordingTimer;
  var _recording = false;
  var _disposed = false;
  var _session = 0;
  var _tempDirCleaned = false;

  bool get isActive => _recording || _cancelToken != null;

  Future<SpeechInputAvailability> initialize({
    required SpeechInputStatusCallback onStatus,
    required SpeechInputErrorCallback onError,
  }) async {
    _statusCallback = onStatus;
    _errorCallback = onError;
    if (_disposed) return SpeechInputAvailability.unavailable;
    try {
      return await _recorder.hasPermission()
          ? SpeechInputAvailability.ready
          : SpeechInputAvailability.permissionDenied;
    } catch (_) {
      return SpeechInputAvailability.unavailable;
    }
  }

  /// Starts a microphone recording. Call [finish] to upload the WAV and get
  /// the final transcript, or [cancel] to discard it without sending data.
  Future<bool> start({
    required MediaApiConfig config,
    required String apiKey,
    required SpeechInputResultCallback onResult,
  }) async {
    if (_disposed) return false;
    if (!config.isConfiguredWith(apiKey)) {
      _errorCallback?.call(
        const SpeechInputFailure(
          code: 'cloud_asr_not_configured',
          permanent: false,
          userFacingMessage: '请先在设置 > 能力中配置 MiMo 云端语音识别 API。',
        ),
      );
      return false;
    }
    if (isActive) await cancel();

    final session = ++_session;
    _resultCallback = onResult;
    try {
      final cache = await _temporaryDirectory();
      final directory = Directory(
        '${cache.path}${Platform.pathSeparator}expert-chat-asr',
      );
      await directory.create(recursive: true);
      if (!_tempDirCleaned) {
        // Clear WAV leftovers of previous sessions once per service lifetime,
        // before the current recording file is created, so cleanup can never
        // touch the clip currently being recorded.
        _tempDirCleaned = true;
        await _deleteStaleTempFiles(directory);
      }
      final file = File(
        '${directory.path}${Platform.pathSeparator}recording-$session.wav',
      );
      _recordingFile = file;
      await _recorder.start(file.path);
      if (!_isCurrent(session)) {
        await _recorder.cancel();
        await _deleteAudioFile(file);
        return false;
      }
      _recording = true;
      _startRecordingTimer();
      _statusCallback?.call(SpeechInputStatus.listening);
      return true;
    } catch (_) {
      if (_isCurrent(session)) {
        _recording = false;
        final file = _recordingFile;
        _recordingFile = null;
        await _deleteAudioFile(file);
        _errorCallback?.call(
          const SpeechInputFailure(
            code: 'record_start_failed',
            permanent: false,
            userFacingMessage: '未能启动录音，请检查麦克风权限后重试。',
          ),
        );
      }
      return false;
    }
  }

  /// Stops recording and submits the captured file to the configured MiMo ASR
  /// endpoint. The transcript is emitted as one final result.
  Future<void> finish({
    required MediaApiConfig config,
    required String apiKey,
    String language = 'auto',
  }) async {
    if (_disposed || !_recording) return;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    final session = _session;
    _recording = false;
    File? file = _recordingFile;
    try {
      final returnedPath = await _recorder.stop();
      if (!_isCurrent(session)) return;
      if (returnedPath != null && returnedPath.trim().isNotEmpty) {
        file = File(returnedPath);
        _recordingFile = file;
      }
      if (file == null || !await file.exists()) {
        throw const FormatException('录音文件未生成，请重新录制。');
      }
      final size = await file.length();
      if (size > _maxRecordingFileBytes) {
        throw FormatException(
          '录音超过 ${_maxRecordingFileBytes ~/ (1024 * 1024)} MB 限制。',
        );
      }
      final bytes = Uint8List.fromList(await file.readAsBytes());
      if (!_isCurrent(session)) return;

      final cancelToken = CancelToken();
      _cancelToken = cancelToken;
      final transcript = await mediaProvider.transcribeMimoSpeech(
        config: config,
        apiKey: apiKey,
        audioBytes: bytes,
        mimeType: 'audio/wav',
        language: language,
        cancelToken: cancelToken,
      );
      if (!_isCurrent(session)) return;
      _resultCallback?.call(SpeechInputResult(text: transcript, isFinal: true));
    } on DioException catch (error) {
      if (!CancelToken.isCancel(error) && _isCurrent(session)) {
        _reportUploadFailure(error);
      }
    } catch (error) {
      if (_isCurrent(session)) _reportUploadFailure(error);
    } finally {
      // Always clean up the captured file: a concurrent cancel() bumps the
      // session while stop() is still pending, so deletion must not depend on
      // the session still being current.
      await _deleteAudioFile(file);
      if (_isCurrent(session)) {
        _cancelToken = null;
        _recordingFile = null;
        _statusCallback?.call(SpeechInputStatus.stopped);
      }
    }
  }

  Future<void> cancel() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    final wasActive = isActive;
    ++_session;
    _recording = false;
    _cancelToken?.cancel('语音识别已取消');
    _cancelToken = null;
    _resultCallback = null;
    final file = _recordingFile;
    _recordingFile = null;
    try {
      // Always stop the underlying recorder: cancel() may run while finish()
      // is still awaiting stop(), in which case _recording is already false
      // but the platform recorder is not yet stopped.
      await _recorder.cancel();
    } catch (_) {
      // A recorder that has already stopped is safe to treat as cancelled.
    }
    await _deleteAudioFile(file);
    if (wasActive) _statusCallback?.call(SpeechInputStatus.stopped);
  }

  /// Removes page callbacks while retaining the recorder for a later page.
  void detach() {
    _resultCallback = null;
    _statusCallback = null;
    _errorCallback = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
    await _recorder.dispose();
    detach();
  }

  void _startRecordingTimer() {
    _recordingTimer?.cancel();
    late final Timer timer;
    timer = Timer(_maxRecordingDuration, () {
      // A stale timer (replaced by a later recording, or finished/cancelled)
      // must never cancel a session it does not own.
      if (!identical(_recordingTimer, timer)) return;
      if (_disposed || !_recording) return;
      _recordingTimer = null;
      _errorCallback?.call(
        SpeechInputFailure(
          code: 'recording_timeout',
          permanent: false,
          userFacingMessage:
              '录音超过 ${_maxRecordingDuration.inSeconds} 秒上限，请重新录制。',
        ),
      );
      unawaited(cancel());
    });
    _recordingTimer = timer;
  }

  bool _isCurrent(int session) => !_disposed && session == _session;

  void _reportUploadFailure(Object error) {
    _errorCallback?.call(
      SpeechInputFailure(
        code: 'cloud_asr_failed',
        permanent: false,
        userFacingMessage: _errorMessage(error),
      ),
    );
  }

  String _errorMessage(Object error) {
    if (error is DioException) {
      // Only a network/API failure earns the cloud troubleshooting copy; the
      // provider humanizes DioExceptions into plain Exceptions with their own
      // detail (handled below), so this branch is the last line of defence.
      return '云端语音识别失败，请检查 API 配置和网络后重试。';
    }
    final raw = error.toString();
    for (final prefix in const ['Exception: ', 'FormatException: ']) {
      if (raw.startsWith(prefix)) return raw.substring(prefix.length);
    }
    // Anything else comes from the recording phase (file reads, recorder
    // stop), so the cloud copy would be misleading here.
    return '录音文件处理失败，请重试。';
  }

  Future<void> _deleteAudioFile(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Do not let a late platform file lock block the next recognition.
    }
  }

  /// Deletes files left in [directory] by previous sessions so the temp
  /// directory does not accumulate WAV clips across launches. Best effort: a
  /// file still held by the platform is skipped rather than retried. Never
  /// throws.
  Future<void> _deleteStaleTempFiles(Directory directory) async {
    try {
      if (!await directory.exists()) return;
      await for (final entry in directory.list()) {
        if (entry is! File) continue;
        try {
          await entry.delete();
        } catch (_) {
          // A locked file is safe to leave for a later session to retry.
        }
      }
    } catch (_) {
      // A failed cleanup must never block the recording that follows it.
    }
  }
}
