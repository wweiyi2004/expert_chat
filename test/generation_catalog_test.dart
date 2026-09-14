import 'package:expert_chat/data/db/app_database.dart' show GenerationRecord;
import 'package:expert_chat/domain/media/generation_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

GenerationRecord record(
  String id, {
  String? parent,
  String prompt = '相同描述',
  String model = 'model',
  String refs = '[]',
}) => GenerationRecord(
  id: id,
  parentGenerationId: parent,
  libraryItemId: 'same-output',
  originalPrompt: prompt,
  optimizedPrompt: prompt,
  model: model,
  providerHost: 'https://example.com',
  imageSize: '1024x1024',
  referencesJson: refs,
  createdAt: DateTime(2026),
);

void main() {
  test(
    'parent links determine series even when prompts and image bytes match',
    () {
      final catalog = GenerationCatalog([
        record('child', parent: 'root'),
        record('unrelated'),
        record('root'),
      ]);
      expect(catalog.seriesId('child'), catalog.seriesId('root'));
      expect(catalog.seriesId('unrelated'), isNot(catalog.seriesId('root')));
      expect(catalog.labels['root'], '版本 1');
      expect(catalog.labels['child'], '版本 2');
      expect(catalog.filter(family: 'root').map((r) => r.id), [
        'child',
        'root',
      ]);
      catalog.filter(query: 'not present');
      expect(catalog.labels['child'], '版本 2');
    },
  );

  test('missing parents and cyclic imports are bounded and deterministic', () {
    final catalog = GenerationCatalog([
      record('a', parent: 'b'),
      record('b', parent: 'a'),
      record('c', parent: 'gone'),
      record('d', parent: 'gone'),
    ]);
    expect(catalog.seriesId('a'), catalog.seriesId('b'));
    expect(catalog.seriesId('c'), catalog.seriesId('d'));
    expect(catalog.relationship(catalog.byId['c']!), '来源版本不在记录中');
    expect(catalog.labels, hasLength(4));
  });

  test('long version chains do not require recursion', () {
    final catalog = GenerationCatalog([
      for (var i = 0; i < 10000; i++)
        record('id$i', parent: i == 0 ? null : 'id${i - 1}'),
    ]);
    expect(catalog.series, hasLength(1));
    expect(catalog.labels['id9999'], '版本 10000');
  });

  test(
    'parameter differences ignore storage ids and compare reference contents',
    () {
      final a = record(
        'a',
        refs: '[{"libraryItemId":"one","sha256":"hash","name":"old.png"}]',
      );
      final b = record(
        'b',
        parent: 'a',
        refs: '[{"libraryItemId":"two","sha256":"hash","name":"new.png"}]',
      );
      expect(GenerationCatalog.changedFields(a, b), isEmpty);
      final c = record(
        'c',
        model: 'new-model',
        refs: '[{"sha256":"new-hash"}]',
      );
      expect(GenerationCatalog.changedFields(a, c), {'模型', '参考图'});
    },
  );
}
