import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/settings_state.dart';
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <Map<String, dynamic>>[];
  int status = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(
      Map<String, dynamic>.from(
        (options.data is String
                ? jsonDecode(options.data as String)
                : options.data)
            as Map,
      ),
    );
    final result = options.path.endsWith('/fetch')
        ? {'title': '页面', 'content': '# Markdown 正文'}
        : {
            'results': [
              {
                'title': '结果',
                'url': 'https://example.com/source',
                'snippet': '短摘要',
                'summary': '供模型阅读的长摘要',
                'content': '',
              },
              {'title': 'unsafe', 'url': 'file:///secret'},
            ],
          };
    return ResponseBody.fromString(
      jsonEncode(result),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('new settings and absent or invalid backend default to DeepSeek', () {
    expect(const SettingsState().searchBackend, SearchBackend.deepseek);
    expect(SearchBackendInfo.fromWire(null), SearchBackend.deepseek);
    expect(SearchBackendInfo.fromWire('unknown'), SearchBackend.deepseek);
  });

  test(
    'Search uses official endpoint, bearer key and summary fallback',
    () async {
      final api = _Api();
      final provider = HttpSearchProvider(
        backend: SearchBackend.deepseek,
        apiKey: 'test-key',
        dio: Dio()..httpClientAdapter = api,
      );
      final results = await provider.search(
        '新模型 site:example.com',
        maxResults: 5,
      );
      expect(
        api.requests.single.uri.toString(),
        'https://api.deepseek.com/v1/tools/search',
      );
      expect(api.requests.single.headers['Authorization'], 'Bearer test-key');
      expect(api.bodies.single, {
        'query': '新模型 site:example.com',
        'count': 5,
        'need_content': true,
      });
      expect(results.single.bestText, '供模型阅读的长摘要');
    },
  );
  test(
    'Fetch uses official API and keeps markdown; rejects unsafe URLs locally',
    () async {
      final api = _Api();
      final provider = HttpSearchProvider(
        backend: SearchBackend.deepseek,
        apiKey: 'test-key',
        dio: Dio()..httpClientAdapter = api,
      );
      final page = await provider.fetchPage('https://example.com/article');
      expect(page.title, '页面');
      expect(page.content, '# Markdown 正文');
      expect(api.requests.single.uri.path, '/v1/tools/fetch');
      expect(api.bodies.single, {'url': 'https://example.com/article'});
      expect(
        (await provider.fetchPage('http://127.0.0.1/admin')).content,
        isEmpty,
      );
      expect(api.requests, hasLength(1));
    },
  );
  test(
    '128 Unicode code points, empty results and authentication failures',
    () async {
      final api = _Api();
      final provider = HttpSearchProvider(
        backend: SearchBackend.deepseek,
        apiKey: 'test-key',
        dio: Dio()..httpClientAdapter = api,
      );
      await provider.search(List.filled(128, '😀').join());
      await expectLater(
        provider.search(List.filled(129, '😀').join()),
        throwsArgumentError,
      );
      expect(api.requests, hasLength(1));
      api.status = 401;
      await expectLater(
        provider.search('test'),
        throwsA(predicate((e) => e.toString().contains('鉴权失败'))),
      );
    },
  );
  test(
    'official provider search reuses its key; gateway needs explicit search key',
    () {
      final official = ProviderProfile(
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        chatModel: 'deepseek-flash',
        reasonerModel: 'deepseek-v4-pro',
      );
      final state = SettingsState(
        profiles: [official],
        activeProfileId: official.id,
        apiKey: 'model-key',
        searchBackend: SearchBackend.provider,
      );
      expect(state.effectiveSearchBackend, SearchBackend.deepseek);
      expect(state.effectiveSearchApiKey, 'model-key');
      expect(
        state
            .copyWith(
              searchBackend: SearchBackend.deepseek,
              searchApiKey: 'explicit-deepseek-search-key',
            )
            .effectiveSearchApiKey,
        'explicit-deepseek-search-key',
      );
      final gateway = official.copyWith(
        baseUrl: 'https://api.deepseek.com.example/v1',
      );
      final other = state.copyWith(
        profiles: [gateway],
        searchBackend: SearchBackend.deepseek,
        searchApiKey: 'search-key',
      );
      expect(other.effectiveSearchApiKey, 'search-key');
    },
  );
}
