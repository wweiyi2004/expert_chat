import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'protocol.dart';

/// Offline ffmpeg helpers for TUI audio/video attachments.
///
/// Every invocation forces the container demuxer from the file extension and
/// whitelists only local file input, so a crafted file cannot make ffmpeg
/// follow playlists or open other protocols.
class MediaExtract {
  const MediaExtract({
    this.ffmpeg = 'ffmpeg',
    this.ffprobe = 'ffprobe',
    this.segmentSeconds = 1200,
  });
  final String ffmpeg, ffprobe;

  static const demuxers = {
    'wav': 'wav',
    'mp3': 'mp3',
    'm4a': 'mov',
    'aac': 'aac',
    'ogg': 'ogg',
    'opus': 'ogg',
    'flac': 'flac',
    'amr': 'amr',
    'weba': 'matroska',
    'wma': 'asf',
    'mp4': 'mov',
    'mov': 'mov',
    'm4v': 'mov',
    '3gp': 'mov',
    'webm': 'matroska',
    'mkv': 'matroska',
    'avi': 'avi',
  };

  /// ASR uploads are capped near 25 MB; 16 kHz mono 32 kbit/s MP3 keeps each
  /// default 20-minute segment around 4.8 MB.
  final int segmentSeconds;

  List<String> _input(String ext, String path, {double? seek}) => [
    '-nostdin',
    '-hide_banner',
    '-loglevel',
    'error',
    '-protocol_whitelist',
    'file,pipe',
    if (seek != null) ...['-ss', seek.toStringAsFixed(2)],
    '-f',
    demuxers[ext] ?? (throw const BridgeFailure('unsupported', '不支持的音视频格式')),
    '-i',
    path,
  ];

  Future<({int code, String error, String log})> _run(
    String exe,
    List<String> args,
    CancelToken token,
    Duration limit,
  ) async {
    final Process process;
    try {
      process = await Process.start(exe, args, runInShell: false);
    } on ProcessException {
      throw const BridgeFailure(
        'dependency_missing',
        '未找到 ffmpeg。请安装 ffmpeg 并加入 PATH，重新启动 expert 后再导入音视频。',
      );
    }
    final cancel = token.whenCancel.then((_) => process.kill());
    unawaited(cancel);
    final errors = <int>[];
    final out = process.stdout.toList();
    final err = process.stderr.listen(errors.addAll).asFuture<void>();
    final code = await process.exitCode.timeout(
      limit,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await Future.wait([out, err]);
    if (token.isCancelled) throw const BridgeFailure('cancelled', '附件导入已取消');
    final text = utf8.decode(errors, allowMalformed: true).trim();
    // ffmpeg ends with a generic line; the first error line names the cause.
    final first = text.split('\n').where((l) => l.trim().isNotEmpty).firstOrNull;
    return (
      code: code,
      error: code == -1 ? '处理超时' : (first ?? '').trim(),
      log: text,
    );
  }

  /// Container duration in seconds, or null when the file does not report one.
  Future<double?> duration(File file, String ext, CancelToken token) async {
    final result = await Process.run(ffprobe, [
      '-v',
      'error',
      '-protocol_whitelist',
      'file,pipe',
      '-f',
      demuxers[ext] ?? 'mov',
      '-show_entries',
      'format=duration',
      '-of',
      'csv=p=0',
      file.path,
    ]).timeout(const Duration(seconds: 20), onTimeout: () => ProcessResult(0, -1, '', ''));
    if (token.isCancelled) throw const BridgeFailure('cancelled', '附件导入已取消');
    final value = double.tryParse('${result.stdout}'.trim());
    return value != null && value.isFinite && value > 0 ? value : null;
  }

  /// Converts any supported audio to 16 kHz mono MP3 segments for ASR.
  Future<List<File>> audioSegments(
    File file,
    String ext,
    Directory dir,
    CancelToken token, {
    bool fromVideo = false,
  }) async {
    final pattern = p.join(dir.path, 'audio-%03d.mp3');
    final result = await _run(ffmpeg, [
      ..._input(ext, file.path),
      '-vn',
      '-map',
      '0:a:0',
      '-ac',
      '1',
      '-ar',
      '16000',
      '-b:a',
      '32k',
      '-f',
      'segment',
      '-segment_time',
      '$segmentSeconds',
      '-reset_timestamps',
      '1',
      pattern,
    ], token, const Duration(minutes: 10));
    final segments = await dir
        .list()
        .where((e) => e is File && p.basename(e.path).startsWith('audio-'))
        .cast<File>()
        .toList();
    segments.sort((a, b) => a.path.compareTo(b.path));
    if (result.code != 0 || segments.isEmpty) {
      final noStream = result.log.contains('matches no streams') ||
          result.log.contains('does not contain any stream');
      if (noStream) {
        throw BridgeFailure(
          'parse_failed',
          fromVideo ? '视频没有音轨' : '文件中没有可识别的音频流',
        );
      }
      throw BridgeFailure(
        'parse_failed',
        '音频转换失败${result.error.isEmpty ? '' : '：${result.error}'}',
      );
    }
    return segments;
  }

  /// Up to three frames spread over the whole video, via fast keyframe seeks
  /// instead of decoding every frame.
  Future<List<File>> videoFrames(
    File file,
    String ext,
    Directory dir,
    CancelToken token,
  ) async {
    final length = await duration(file, ext, token);
    final points = length == null || length < 3
        ? [0.0]
        : [length * 0.1, length * 0.5, length * 0.9];
    final frames = <File>[];
    String lastError = '';
    for (final (i, at) in points.indexed) {
      final target = File(p.join(dir.path, 'frame-${i.toString().padLeft(2, '0')}.jpg'));
      final result = await _run(ffmpeg, [
        ..._input(ext, file.path, seek: at),
        '-frames:v',
        '1',
        '-vf',
        'scale=w=640:h=640:force_original_aspect_ratio=decrease',
        '-q:v',
        '5',
        target.path,
      ], token, const Duration(seconds: 20));
      if (result.code == 0 && await target.exists() && await target.length() > 0) {
        frames.add(target);
      } else {
        lastError = result.error;
      }
    }
    if (frames.isEmpty) {
      throw BridgeFailure(
        'parse_failed',
        '视频抽帧失败${lastError.isEmpty ? '' : '：$lastError'}，请检查文件是否完整',
      );
    }
    return frames;
  }

  /// "1:23" or "1:02:03" for a frame timestamp.
  static String clock(double seconds) {
    final s = seconds.round();
    final h = s ~/ 3600, m = s % 3600 ~/ 60, r = s % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(r)}' : '$m:${two(r)}';
  }
}
