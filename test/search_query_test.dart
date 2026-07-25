import 'package:characters/characters.dart';
import 'package:expert_chat/domain/tools/search_query.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeSearchQuery', () {
    test('trims and collapses whitespace', () {
      expect(normalizeSearchQuery('  foo   bar \n\n baz  '), 'foo bar\nbaz');
    });

    test('strips common Chinese chat prefixes', () {
      expect(normalizeSearchQuery('请问DeepSeek V3 定价'), 'DeepSeek V3 定价');
      expect(normalizeSearchQuery('帮我 查一下上海天气'), '查一下上海天气');
      expect(
        normalizeSearchQuery('我想知道 GPT-4o context window'),
        'GPT-4o context window',
      );
    });

    test('clips long queries near a natural break', () {
      final long =
          '请告诉我关于人工智能大语言模型在2024到2026年间的定价策略、'
          '上下文窗口变化、以及各厂商 API 限流策略的详细对比，'
          '最好包含官方文档链接和第三方评测数据。';
      final out = normalizeSearchQuery(long, maxChars: 40);
      expect(out.characters.length, lessThanOrEqualTo(40));
      expect(out, isNot(contains('请告诉我')));
      expect(out.isNotEmpty, isTrue);
    });

    test('returns empty for blank input', () {
      expect(normalizeSearchQuery('   '), isEmpty);
      expect(normalizeSearchQuery('请'), isEmpty);
    });
  });
}
