import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/tools/vision_tools.dart';
import 'package:flutter_test/flutter_test.dart';

Attachment _img(String name, {String id = ''}) => Attachment(
  id: id.isEmpty ? name : id,
  name: name,
  mimeType: 'image/png',
  imageBase64: 'aaaa',
);

void main() {
  group('VisionTools.parseArgs', () {
    test('reads attachment_name and question', () {
      final args = VisionTools.parseArgs(
        '{"attachment_name":"a.png","question":"图上写了什么"}',
      );
      expect(args.attachmentName, 'a.png');
      expect(args.resolvedQuestion, '图上写了什么');
    });

    test('accepts filename/prompt aliases and defaults the question', () {
      final args = VisionTools.parseArgs('{"filename":"b.jpg"}');
      expect(args.attachmentName, 'b.jpg');
      expect(args.resolvedQuestion, VisionTools.defaultQuestion);
    });

    test('tolerates malformed JSON', () {
      final args = VisionTools.parseArgs('not-json');
      expect(args.attachmentName, isEmpty);
      expect(args.resolvedQuestion, VisionTools.defaultQuestion);
    });
  });

  group('VisionTools.pickImage', () {
    test('picks by name, case-insensitive', () {
      final sources = [_img('Cat.PNG'), _img('dog.jpg')];
      expect(VisionTools.pickImage(sources, 'cat.png')?.name, 'Cat.PNG');
    });

    test('falls back to the latest image when name is omitted', () {
      final sources = [_img('a.png'), _img('b.png')];
      expect(VisionTools.pickImage(sources, null)?.name, 'b.png');
    });

    test('returns null for an unknown name', () {
      expect(VisionTools.pickImage([_img('a.png')], 'missing.png'), isNull);
    });
  });

  test('SearchActivity persists the vision kind', () {
    final activity = SearchActivity(
      kind: SearchActivityKind.vision,
      query: 'shot.png',
      status: SearchActivityStatus.done,
      resultCount: 1,
    );
    final restored = SearchActivity.fromJson(activity.toJson());
    expect(restored.kind, SearchActivityKind.vision);
    expect(restored.query, 'shot.png');
    expect(restored.status, SearchActivityStatus.done);
  });
}
