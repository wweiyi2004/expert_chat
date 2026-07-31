import 'dart:convert';

import 'package:expert_chat/domain/story/studio_asset_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodeJsonText decodes UTF-8 JSON bytes', () {
    expect(
      StudioAssetIo.decodeJsonText(utf8.encode('{"title": "雾港夜车"}')),
      '{"title": "雾港夜车"}',
    );
  });

  test('decodeJsonText explains non-UTF-8 (GBK) bytes instead of failing',
      () {
    // GBK 编码的「测试」— 不是合法的 UTF-8 字节序列。
    final gbkBytes = <int>[0xB2, 0xE2, 0xCA, 0xD4];
    expect(
      () => StudioAssetIo.decodeJsonText(gbkBytes),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('UTF-8'),
        ),
      ),
    );
  });
}
