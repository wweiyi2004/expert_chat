import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/tools/attachment_ingestor.dart';
import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:flutter_test/flutter_test.dart';

class _Parser extends FileParser {
  final names = <String>[];
  final payloads = <List<int>>[];
  Future<Attachment> Function(Attachment)? response;

  @override
  Future<Attachment> parseAsync({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) async {
    names.add(name);
    payloads.add(List.of(bytes));
    final result = Attachment(
      name: name,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      text: utf8.decode(bytes),
      imageBase64: base64Encode(bytes),
    );
    return response == null ? result : await response!(result);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Parser parser;
  late AttachmentIngestor ingestor;
  late bool current;
  setUp(() {
    parser = _Parser();
    ingestor = AttachmentIngestor(parser: parser);
    current = true;
  });
  Future<AttachmentIngestResult> run(
    List<FileIngestSource> sources, {
    int slots = 8,
    int existing = 0,
  }) => ingestor.ingest(
    sources,
    slots: slots,
    existingBytes: existing,
    isCurrent: () => current,
  );
  FileIngestSource source(String name, String text) => FileIngestSource(
    name: name,
    extension: 'txt',
    bytes: Uint8List.fromList(utf8.encode(text)),
  );

  test(
    'bytes, bounded streams and lazy sources share ordered parsing',
    () async {
      final result = await run([
        source('bytes.txt', 'one'),
        FileIngestSource(
          name: 'stream.md',
          extension: 'MD',
          stream: Stream.fromIterable([
            [116, 119],
            [111],
          ]),
        ),
        FileIngestSource(
          name: 'album.txt',
          extension: 'txt',
          loadBytes: () async => Uint8List.fromList(utf8.encode('three')),
        ),
      ]);
      expect(parser.names, ['bytes.txt', 'stream.md', 'album.txt']);
      expect(result.attachments.map((a) => a.text), ['one', 'two', 'three']);
      expect(result.attachments[1].mimeType, 'text/markdown');
      expect(() => result.attachments.clear(), throwsUnsupportedError);
    },
  );

  test('slot and reported size limits prevent unnecessary reads', () async {
    var reads = 0;
    FileIngestSource lazy(String name, {int? reported}) => FileIngestSource(
      name: name,
      extension: 'txt',
      reportedSize: reported,
      loadBytes: () async {
        reads++;
        return Uint8List.fromList([65]);
      },
    );
    final result = await run([
      lazy('too-big.txt', reported: AttachmentIngestor.maxAttachmentBytes + 1),
      source('accepted.txt', 'ok'),
      lazy('no-slot.txt'),
    ], slots: 1);
    expect(reads, 0);
    expect(result.tooLarge, 1);
    expect(result.tooMany, 1);
    expect(parser.names, ['accepted.txt']);
  });

  test('inaccurate size reports cannot bypass bounded stream reads', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    stream.add(Uint8List(AttachmentIngestor.maxAttachmentBytes + 1));
    final result = await run([
      FileIngestSource(
        name: 'large.txt',
        extension: 'txt',
        reportedSize: 1,
        stream: stream.stream,
      ),
    ]);
    expect(result.tooLarge, 1);
    expect(cancelled, isTrue);
    expect(parser.names, isEmpty);
    await stream.close();
  });

  test('remaining total limits streams and inline bytes', () async {
    final result = await run([
      FileIngestSource(
        name: 'stream.txt',
        extension: 'txt',
        stream: Stream.value([1, 2, 3]),
      ),
      source('bytes.txt', 'abc'),
      source('fits.txt', 'ok'),
    ], existing: AttachmentIngestor.maxTotalAttachmentBytes - 2);
    expect(result.overTotal, 2);
    expect(result.attachments.single.name, 'fits.txt');
  });

  test('read and parser failures skip only the affected files', () async {
    parser.response = (a) async {
      if (a.name == 'broken.txt') throw StateError('parse failed');
      return a.copyWith(truncated: true);
    };
    final result = await run([
      const FileIngestSource(name: 'missing.txt'),
      FileIngestSource(name: 'empty.txt', loadBytes: () async => null),
      FileIngestSource(
        name: 'error.txt',
        stream: Stream.error(StateError('read failed')),
      ),
      source('broken.txt', 'broken'),
      source('valid.txt', 'valid'),
    ]);
    expect(result.unreadable, 4);
    expect(result.attachments.single.name, 'valid.txt');
    expect(result.attachments.single.truncated, isTrue);
  });

  test('stale operation before reading does no work', () async {
    current = false;
    final result = await run([source('ignored.txt', 'ignore')]);
    expect(result.cancelled, isTrue);
    expect(parser.names, isEmpty);
  });

  test(
    'stale operation after reading stops before parsing or loading next file',
    () async {
      var nextReads = 0;
      final result = await run([
        FileIngestSource(
          name: 'first.txt',
          loadBytes: () async {
            current = false;
            return Uint8List.fromList([65]);
          },
        ),
        FileIngestSource(
          name: 'next.txt',
          loadBytes: () async {
            nextReads++;
            return Uint8List.fromList([65]);
          },
        ),
      ]);
      expect(result.cancelled, isTrue);
      expect(result.attachments, isEmpty);
      expect(parser.names, isEmpty);
      expect(nextReads, 0);
    },
  );

  test(
    'stale operation after parsing discards the entire prepared batch',
    () async {
      parser.response = (a) async {
        if (a.name == 'second.txt') current = false;
        return a;
      };
      final result = await run([
        source('first.txt', '1'),
        source('second.txt', '2'),
        source('third.txt', '3'),
      ]);
      expect(result.cancelled, isTrue);
      expect(result.attachments, isEmpty);
      expect(parser.names, ['first.txt', 'second.txt']);
    },
  );

  test(
    'image byte limit produces a parse error without invoking document parser',
    () async {
      final result = await run([
        FileIngestSource(
          name: 'large.png',
          extension: 'png',
          bytes: Uint8List(FileParser.maxImageBytes + 1),
        ),
      ]);
      expect(result.attachments.single.parseError, contains('超过 5MB'));
      expect(result.attachments.single.hasImageData, isFalse);
      expect(parser.names, isEmpty);
    },
  );

  test('small images preserve downloadable bytes and image identity', () async {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    final result = await run([
      FileIngestSource(name: 'clipboard.png', extension: 'png', bytes: bytes),
    ]);
    final image = result.attachments.single;
    expect(image.name, 'clipboard.png');
    expect(image.mimeType, 'image/png');
    expect(base64Decode(image.imageBase64!), bytes);
    expect(parser.names, isEmpty);
  });
}
