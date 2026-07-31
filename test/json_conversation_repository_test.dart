import 'dart:convert';
import 'dart:io';

import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('expert_chat_json_repo');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File fileFor(String name) =>
      File('${tempDir.path}${Platform.pathSeparator}$name');

  group('JsonConversationRepository', () {
    test('returns empty when the file does not exist', () async {
      final repo = JsonConversationRepository(file: fileFor('missing.json'));

      expect(await repo.loadAll(), isEmpty);
    });

    test('skips corrupt entries and keeps the healthy part', () async {
      final file = fileFor('conversations.json');
      file.writeAsStringSync(jsonEncode([
        {
          'id': 'healthy',
          'title': '健康会话',
          'updatedAt': '2026-01-01T00:00:00.000Z',
          'messages': [
            {
              'id': 'm1',
              'role': 'user',
              'content': 'hello',
              'createdAt': '2026-01-01T00:00:00.000Z',
            },
          ],
        },
        {
          'id': 'corrupt-entry',
          'activeChildren': 'not-a-map',
        },
        'a bare string entry',
      ]));
      final repo = JsonConversationRepository(file: file);

      final all = await repo.loadAll();

      expect(all.map((c) => c.id), ['healthy']);
    });

    test(
      'throws on an undecodable file and backs it up before the next write',
      () async {
        final file = fileFor('conversations.json');
        file.writeAsStringSync('[{"id": "truncated"');
        final repo = JsonConversationRepository(file: file);

        await expectLater(
          repo.loadAll(),
          throwsA(isA<JsonHistoryCorruptedException>()),
        );

        await repo.saveConversation(
          Conversation(id: 'new-convo', title: '新会话'),
        );

        final backups = tempDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.corrupt-'))
            .toList();
        expect(backups, hasLength(1));
        expect(backups.single.readAsStringSync(), contains('truncated'));
        expect(file.readAsStringSync(), contains('new-convo'));
      },
    );

    test('tolerates numeric timestamps and activeChildren values', () async {
      final file = fileFor('conversations.json');
      file.writeAsStringSync(jsonEncode([
        {
          'id': 'num-fields',
          'title': '数字字段',
          'updatedAt': 1700000000000,
          'activeChildren': {'': 123, 'user-1': 'assistant-1'},
          'messages': [
            {
              'id': 'm1',
              'role': 'user',
              'content': 'hi',
              'createdAt': 1700000000000,
            },
          ],
        },
      ]));
      final repo = JsonConversationRepository(file: file);

      final all = await repo.loadAll();

      expect(all, hasLength(1));
      final conversation = all.single;
      expect(conversation.activeChildren, {
        '': '123',
        'user-1': 'assistant-1',
      });
      expect(
        conversation.updatedAt.millisecondsSinceEpoch,
        1700000000000,
      );
      expect(
        conversation.messages.single.createdAt.millisecondsSinceEpoch,
        1700000000000,
      );
    });
  });
}
