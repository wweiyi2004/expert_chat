import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

final _states = Expando<_ProxyState>();

class _ProxyState {
  String proxy = 'DIRECT';
}

DateTime? _checked;
Future<String>? _pending;

/// Match the system browser's proxy for official OpenAI traffic. TLS validation
/// is unchanged; loopback callbacks and all other hosts remain direct.
Future<void> configureChatGptNetwork(Dio dio) async {
  if (dio.httpClientAdapter is! IOHttpClientAdapter) return;
  var state = _states[dio];
  if (state == null) {
    state = _ProxyState();
    _states[dio] = state;
    final proxyState = state;
    final previous = dio.httpClientAdapter as IOHttpClientAdapter;
    dio.httpClientAdapter = IOHttpClientAdapter(
      validateCertificate: previous.validateCertificate,
      createHttpClient: () =>
          (previous.createHttpClient?.call() ?? HttpClient())
            ..findProxy = (uri) =>
                uri.scheme == 'https' &&
                    (uri.host == 'auth.openai.com' ||
                        uri.host == 'api.openai.com')
                ? proxyState.proxy
                : 'DIRECT',
    );
    // Replacing the factory alone would keep an already cached direct client.
    // Let existing requests drain while new requests use the new adapter.
    previous.close(force: false);
  }
  if (_pending == null ||
      _checked == null ||
      DateTime.now().difference(_checked!) > const Duration(seconds: 15)) {
    _checked = DateTime.now();
    _pending = _systemProxy();
  }
  state.proxy = await _pending!;
}

String proxyDirective(String value) {
  final sections = value
      .split(';')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  var address =
      sections.where((s) => s.startsWith('https=')).firstOrNull?.substring(6) ??
      sections.where((s) => s.startsWith('http=')).firstOrNull?.substring(5) ??
      sections.where((s) => !s.contains('=')).firstOrNull ??
      '';
  if (address.isEmpty) return 'DIRECT';
  final uri = Uri.tryParse(
    address.contains('://') ? address : 'http://$address',
  );
  if (uri == null ||
      uri.scheme != 'http' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !uri.hasPort) {
    return 'DIRECT';
  }
  return 'PROXY ${uri.host.contains(':') ? '[${uri.host}]' : uri.host}:${uri.port}';
}

Future<String> _systemProxy() async {
  final env = Platform.environment;
  final configured =
      env['HTTPS_PROXY'] ??
      env['https_proxy'] ??
      env['HTTP_PROXY'] ??
      env['http_proxy'];
  if (configured != null && configured.isNotEmpty) {
    return proxyDirective(configured);
  }
  if (!Platform.isWindows) return 'DIRECT';
  const path =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  Future<String> read(String name) async {
    final result = await Process.run('reg.exe', [
      'query',
      path,
      '/v',
      name,
    ], runInShell: false).timeout(const Duration(seconds: 3));
    return result.exitCode == 0 ? result.stdout.toString() : '';
  }

  try {
    if (!RegExp(r'REG_DWORD\s+0x1\b').hasMatch(await read('ProxyEnable'))) {
      return 'DIRECT';
    }
    final server =
        RegExp(
          r'REG_SZ\s+([^\r\n]+)',
        ).firstMatch(await read('ProxyServer'))?.group(1) ??
        '';
    return proxyDirective(server.trim());
  } catch (_) {
    return 'DIRECT';
  }
}
