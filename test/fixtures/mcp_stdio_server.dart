import 'dart:async';
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  var initialized = false;
  var calls = 0;
  void reply(Object id, Map<String, dynamic> result) => stdout.writeln(
    jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
  );
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) async {
          final request = jsonDecode(line) as Map;
          final id = request['id'];
          final params = request['params'] as Map? ?? {};
          switch (request['method']) {
            case 'initialize':
              reply(id, {
                'protocolVersion': args.contains('bad-version')
                    ? '2099-01-01'
                    : '2025-06-18',
                'serverInfo': {'name': 'fixture', 'version': '1'},
                'capabilities': {'tools': {}},
              });
            case 'notifications/initialized':
              initialized = true;
            case 'tools/list':
              if (!initialized || params.containsKey('_meta')) {
                stdout.writeln(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': id,
                    'error': {'code': -32600, 'message': 'bad init'},
                  }),
                );
                return;
              }
              reply(id, {
                'tools': [
                  {
                    'name': params['cursor'] == null ? 'echo' : 'other',
                    'description': 'test',
                    'inputSchema': {'type': 'object'},
                  },
                ],
                if (params['cursor'] == null) 'nextCursor': 'page2',
              });
            case 'tools/call':
              calls++;
              final name = params['name'];
              if (name == 'die') exit(1);
              if (name == 'invalid') {
                stdout.writeln('not json');
                return;
              }
              if (name == 'slow') {
                await Future<void>.delayed(const Duration(seconds: 5));
              }
              reply(id, {
                'content': [
                  {
                    'type': 'text',
                    'text': jsonEncode({
                      'calls': calls,
                      'args': params['arguments'],
                      'pid': pid,
                    }),
                  },
                ],
                'isError': false,
              });
            case 'notifications/cancelled':
              if (args.isNotEmpty && args.first.endsWith('.marker')) {
                File(args.first).writeAsStringSync('cancelled');
              }
            default:
              if (id != null) reply(id, {});
          }
        },
        onDone: () {
          exit(0);
        },
      );
}
