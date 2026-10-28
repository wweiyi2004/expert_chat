import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/host/external_sessions.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Windows long session paths do not abort startup discovery', () async {
    final home = await Directory.systemTemp.createTemp('session-long-path-');
    String ioPath(String path) => Platform.isWindows ? r'\\?\' + path : path;
    addTearDown(() => Directory(ioPath(home.path)).delete(recursive: true));
    final nested = p.join(
      home.path,
      '.grok',
      'sessions',
      'a' * 100,
      'b' * 100,
      'c' * 100,
    );
    await Directory(ioPath(nested)).create(recursive: true);
    await File(ioPath(p.join(nested, 'session.jsonl'))).writeAsString(
      jsonEncode({
        'params': {
          'update': {
            'sessionUpdate': 'user_message_chunk',
            'content': {'text': 'long path transcript'},
          },
        },
      }),
    );
    final ordinary = Directory(
      p.join(home.path, '.claude', 'projects', 'example'),
    );
    await ordinary.create(recursive: true);
    await File(
      p.join(ordinary.path, 'broken.jsonl'),
    ).writeAsString('not valid JSON');
    final rows = await ExternalSessionService(home: home.path).discover();
    expect(rows, hasLength(1));
    expect(rows.single.source, 'Grok Build');
    expect(rows.single.messages.single['text'], 'long path transcript');
  });
  test(
    'Claude and Codex import conversation text without instructions, reasoning or tool calls',
    () {
      final claude = [
        {
          'type': 'system',
          'message': {'role': 'system', 'content': 'NEVER_IMPORT'},
        },
        {
          'uuid': 'u',
          'type': 'user',
          'message': {'role': 'user', 'content': 'hello'},
        },
        {
          'uuid': 'a',
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'thinking', 'thinking': 'private'},
              {'type': 'text', 'text': 'answer'},
              {'type': 'tool_use', 'name': 'shell'},
            ],
          },
        },
      ].map(jsonEncode).join('\n');
      expect(parseExternalMessages('Claude Code', claude), [
        {'role': 'user', 'text': 'hello'},
        {'role': 'assistant', 'text': 'answer'},
      ]);
      final codex = [
        {
          'type': 'session_meta',
          'payload': {'base_instructions': 'NEVER_IMPORT'},
        },
        {
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'id': 'a',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'answer'},
            ],
          },
        },
      ].map(jsonEncode).join('\n');
      expect(parseExternalMessages('Codex', codex), [
        {'role': 'assistant', 'text': 'answer'},
      ]);
    },
  );
  test(
    'Grok chunks preserve whitespace, omit thoughts and deduplicate events',
    () {
      String row(String id, String kind, String value) => jsonEncode({
        'params': {
          '_meta': {'eventId': id},
          'update': {
            'sessionUpdate': kind,
            'content': {'text': value},
          },
        },
      });
      final text = [
        row('1', 'user_message_chunk', 'hi'),
        row('2', 'agent_thought_chunk', 'private'),
        row('3', 'agent_message_chunk', 'hello '),
        row('4', 'agent_message_chunk', 'world'),
        row('4', 'agent_message_chunk', 'world'),
      ].join('\n');
      expect(parseExternalMessages('Grok Build', text), [
        {'role': 'user', 'text': 'hi'},
        {'role': 'assistant', 'text': 'hello world'},
      ]);
    },
  );
  test('DSH uses user and assistant text but never tool/permission events', () {
    final text = [
      {
        'type': 'user/message',
        'data': {
          'id': '1',
          'content': [
            {'type': 'text', 'text': 'request'},
          ],
        },
      },
      {
        'type': 'assistant/message',
        'data': {
          'message': {
            'id': '2',
            'content': [
              {'type': 'reasoning', 'text': 'private'},
              {'type': 'text', 'text': 'result'},
            ],
          },
        },
      },
      {
        'type': 'approval/policy',
        'data': {'policy': 'full'},
      },
    ].map(jsonEncode).join('\n');
    expect(parseExternalMessages('DeepSeek Harness', text), [
      {'role': 'user', 'text': 'request'},
      {'role': 'assistant', 'text': 'result'},
    ]);
  });
  test(
    'discovery leaves sources untouched and changed source invalidates reviewed import',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'external-session-test-',
      );
      addTearDown(() => home.delete(recursive: true));
      final dir = await Directory(
        p.join(home.path, '.claude', 'projects', 'synthetic'),
      ).create(recursive: true);
      final file = File(p.join(dir.path, 'session.jsonl'));
      final raw = jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': 'synthetic session'},
      });
      await file.writeAsString(raw);
      final service = ExternalSessionService(home: home.path);
      final result = await service.discover();
      expect(result, hasLength(1));
      expect(await file.readAsString(), raw);
      expect(
        (await service.reviewed(
          result.single.id,
          result.single.fingerprint,
        )).messages.single['text'],
        'synthetic session',
      );
      await file.writeAsString(
        jsonEncode({
          'type': 'user',
          'message': {'role': 'user', 'content': 'changed'},
        }),
      );
      await expectLater(
        service.reviewed(result.single.id, result.single.fingerprint),
        throwsStateError,
      );
    },
  );
}
