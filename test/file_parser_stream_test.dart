import 'dart:typed_data';

import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('readBytesWithLimit returns streamed bytes within the limit', () async {
    final bytes = await FileParser.readBytesWithLimit(
      Stream<List<int>>.fromIterable(const [
        [1, 2],
        [3, 4],
      ]),
      maxBytes: 4,
    );

    expect(bytes, Uint8List.fromList([1, 2, 3, 4]));
  });

  test('readBytesWithLimit rejects a stream above the limit', () async {
    final read = FileParser.readBytesWithLimit(
      Stream<List<int>>.fromIterable(const [
        [1, 2, 3],
        [4, 5],
      ]),
      maxBytes: 4,
    );

    await expectLater(read, throwsA(isA<FileReadLimitExceeded>()));
  });
}
