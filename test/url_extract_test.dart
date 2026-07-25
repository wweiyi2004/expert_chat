import 'package:expert_chat/domain/tools/url_extract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractHttpUrls', () {
    test('extracts bare http(s) urls', () {
      expect(
        extractHttpUrls('看看这个 https://example.com/a 和 http://foo.bar/x'),
        ['https://example.com/a', 'http://foo.bar/x'],
      );
    });

    test('strips trailing punctuation from chat text', () {
      expect(
        extractHttpUrls('链接：https://example.com/page。'),
        ['https://example.com/page'],
      );
      expect(
        extractHttpUrls('(https://example.com/docs)'),
        ['https://example.com/docs'],
      );
    });

    test('dedupes and respects limit', () {
      final text =
          'https://a.com https://b.com https://a.com https://c.com https://d.com';
      expect(extractHttpUrls(text, limit: 2), [
        'https://a.com',
        'https://b.com',
      ]);
    });

    test('skips empty and unsafe schemes', () {
      expect(extractHttpUrls(''), isEmpty);
      expect(extractHttpUrls('no links here'), isEmpty);
      expect(extractHttpUrls('javascript:alert(1)'), isEmpty);
      expect(extractHttpUrls('file:///etc/passwd'), isEmpty);
    });

    test('skips localhost / private-looking hosts via safety check', () {
      expect(extractHttpUrls('http://127.0.0.1/secret'), isEmpty);
      expect(extractHttpUrls('http://localhost/admin'), isEmpty);
    });
  });
}
