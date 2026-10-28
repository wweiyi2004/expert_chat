import 'dart:io';

import 'package:dio/dio.dart';
import 'package:expert_chat/features/tui_bridge/media_extract.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Exercises the real ffmpeg binary; skipped where ffmpeg is not installed.
void main() {
  final hasFfmpeg = () {
    try {
      return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('media-extract-test-'));
  tearDown(() => root.delete(recursive: true));

  Future<File> make(String name, List<String> args) async {
    final out = File(p.join(root.path, name));
    final result = await Process.run('ffmpeg', [
      '-y',
      '-loglevel',
      'error',
      ...args,
      out.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return out;
  }

  Future<Directory> work() => Directory(p.join(root.path, 'work-${DateTime.now().microsecondsSinceEpoch}')).create();
  String code(Object error) => (error as BridgeFailure).code;

  test('frames are spread over the whole video, not only its first minute', () async {
    final video = await make('clip.mp4', [
      '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30',
      '-f', 'lavfi', '-i', 'sine=frequency=440',
      '-t', '90', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '300', '-c:a', 'aac', '-shortest',
    ]);
    const media = MediaExtract();
    expect(await media.duration(video, 'mp4', CancelToken()), closeTo(90, 1));
    final frames = await media.videoFrames(video, 'mp4', await work(), CancelToken());
    expect(frames, hasLength(3));
    for (final frame in frames) {
      expect(await frame.length(), greaterThan(1000));
    }
    expect(MediaExtract.clock(81), '1:21');
    expect(MediaExtract.clock(3723), '1:02:03');
  }, skip: !hasFfmpeg, timeout: const Timeout(Duration(minutes: 2)));

  test('audio from any container becomes small ASR-ready mp3 segments', () async {
    final audio = await make('talk.m4a', [
      '-f', 'lavfi', '-i', 'sine=frequency=300:sample_rate=48000', '-t', '25', '-c:a', 'aac',
    ]);
    const media = MediaExtract(segmentSeconds: 10);
    final segments = await media.audioSegments(audio, 'm4a', await work(), CancelToken());
    expect(segments, hasLength(3), reason: '25 s split every 10 s');
    for (final segment in segments) {
      final size = await segment.length();
      expect(size, inInclusiveRange(1000, 60 * 1024));
    }
  }, skip: !hasFfmpeg, timeout: const Timeout(Duration(minutes: 2)));

  test('a silent video reports a missing audio track instead of a crash', () async {
    final video = await make('silent.mp4', [
      '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=10', '-t', '4', '-c:v', 'libx264', '-preset', 'ultrafast',
    ]);
    await expectLater(
      const MediaExtract().audioSegments(video, 'mp4', await work(), CancelToken(), fromVideo: true),
      throwsA(isA<BridgeFailure>().having((f) => f.message, 'message', '视频没有音轨')),
    );
  }, skip: !hasFfmpeg, timeout: const Timeout(Duration(minutes: 2)));

  test('a broken file fails with ffmpeg\'s own reason', () async {
    final broken = File(p.join(root.path, 'broken.mp4'))..writeAsBytesSync(List.filled(4096, 7));
    try {
      await const MediaExtract().videoFrames(broken, 'mp4', await work(), CancelToken());
      fail('expected failure');
    } on BridgeFailure catch (failure) {
      expect(failure.code, 'parse_failed');
      expect(failure.message, startsWith('视频抽帧失败：'));
    }
  }, skip: !hasFfmpeg);

  test('a playlist disguised as video is never followed', () async {
    final secret = File(p.join(root.path, 'secret.txt'))..writeAsStringSync('do-not-read');
    final playlist = File(p.join(root.path, 'evil.mp4'))
      ..writeAsStringSync('#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10.0,\n${secret.path}\n#EXT-X-ENDLIST\n');
    final out = await work();
    await expectLater(
      const MediaExtract().videoFrames(playlist, 'mp4', out, CancelToken()),
      throwsA(isA<BridgeFailure>()),
    );
    expect(out.listSync(), isEmpty);
  }, skip: !hasFfmpeg);

  test('missing ffmpeg is reported as a dependency problem', () async {
    final file = File(p.join(root.path, 'a.wav'))..writeAsBytesSync([0]);
    try {
      await const MediaExtract(ffmpeg: 'expert-no-such-ffmpeg')
          .audioSegments(file, 'wav', await work(), CancelToken());
      fail('expected failure');
    } catch (error) {
      expect(code(error), 'dependency_missing');
    }
  });
}
