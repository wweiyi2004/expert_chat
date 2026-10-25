import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 5 ||
      args[0] != 'web' ||
      !args.contains('--gateway') ||
      !args.contains('--no-open') ||
      Platform.environment['MAGPIE_NO_ACCOUNTS'] != '1' ||
      Platform.environment['DO_NOT_TRACK'] != '1') {
    exit(64);
  }
  final api = Platform.environment['MAGPIE_ADDR']!.split(':');
  final web = args[args.indexOf('--addr') + 1].split(':');
  final config = Directory(Platform.environment['XDG_CONFIG_HOME']!);
  await config.create(recursive: true);
  await File('${config.path}/fixture-audit.json').writeAsString(
    jsonEncode({
      'accountDiscovery': false,
      'telemetry': false,
      'gatewayMode': true,
      'apiHost': api[0],
      'webHost': web[0],
    }),
  );
  final gateway = await HttpServer.bind(api[0], int.parse(api[1]));
  final management = await HttpServer.bind(web[0], int.parse(web[1]));
  gateway.listen((request) async {
    await request.drain<void>();
    if (request.uri.path == '/v1/models') {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"data":[{"id":"fixture/provider-model"}]}');
    } else if (request.uri.path == '/v1/chat/completions') {
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"companion model fixture"},"finish_reason":null}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
      );
    } else {
      request.response.statusCode = 404;
    }
    await request.response.close();
  });
  management.listen((request) async {
    if (request.uri.queryParameters['k'] !=
        Platform.environment['MAGPIE_WEB_KEY']) {
      request.response.statusCode = 401;
    }
    request.response.write('fixture account management');
    await request.response.close();
  });
}
