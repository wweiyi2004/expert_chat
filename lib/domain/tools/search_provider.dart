import 'package:dio/dio.dart';

/// One web search hit. [content] is the fullest text available (raw page or
/// summary); [snippet] is a short description. Either may be empty.
class SearchResult {
  const SearchResult({
    required this.title,
    required this.url,
    this.snippet = '',
    this.content = '',
  });

  final String title;
  final String url;
  final String snippet;
  final String content;

  /// Best available text for injection into the prompt.
  String get bestText => content.trim().isNotEmpty ? content : snippet;
}

/// Selectable search backends. The user supplies their own key (pure client).
enum SearchBackend { tavily, bocha, exa }

extension SearchBackendInfo on SearchBackend {
  String get label => switch (this) {
        SearchBackend.tavily => 'Tavily',
        SearchBackend.bocha => '博查 Bocha（中文）',
        SearchBackend.exa => 'Exa',
      };

  String get wire => name;

  static SearchBackend fromWire(String? v) => SearchBackend.values.firstWhere(
        (b) => b.name == v,
        orElse: () => SearchBackend.tavily,
      );
}

/// Abstraction over a search API. Native/desktop fetch directly; on Web these
/// calls are CORS-gated (handled by the caller).
abstract class SearchProvider {
  Future<List<SearchResult>> search(String query, {int maxResults = 5});
}

/// Dispatches to the configured backend. Throws a human-readable [Exception]
/// on failure so the chat layer can surface it.
class HttpSearchProvider implements SearchProvider {
  HttpSearchProvider({
    required this.backend,
    required this.apiKey,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
            ));

  final SearchBackend backend;
  final String apiKey;
  final Dio _dio;

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('未配置联网搜索的 API Key，请在设置中填写。');
    }
    try {
      return switch (backend) {
        SearchBackend.tavily => await _tavily(query, maxResults),
        SearchBackend.bocha => await _bocha(query, maxResults),
        SearchBackend.exa => await _exa(query, maxResults),
      };
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw Exception('搜索鉴权失败（$status）：请检查搜索 API Key。');
      }
      throw Exception('联网搜索失败：${e.message ?? e.type.name}');
    }
  }

  Future<List<SearchResult>> _tavily(String query, int maxResults) async {
    final r = await _dio.post<Map<String, dynamic>>(
      'https://api.tavily.com/search',
      options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
      data: {
        'query': query,
        'max_results': maxResults,
        'search_depth': 'basic',
        'include_raw_content': 'text',
        'include_answer': false,
      },
    );
    final results = (r.data?['results'] as List<dynamic>? ?? []);
    return [
      for (final e in results.cast<Map<String, dynamic>>())
        SearchResult(
          title: e['title'] as String? ?? '',
          url: e['url'] as String? ?? '',
          snippet: e['content'] as String? ?? '',
          content: e['raw_content'] as String? ?? '',
        ),
    ];
  }

  Future<List<SearchResult>> _bocha(String query, int maxResults) async {
    final r = await _dio.post<Map<String, dynamic>>(
      'https://api.bochaai.com/v1/web-search',
      options: Options(headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      }),
      data: {
        'query': query,
        'count': maxResults,
        'summary': true,
        'freshness': 'noLimit',
      },
    );
    final value = (r.data?['data']?['webPages']?['value'] as List<dynamic>? ?? []);
    return [
      for (final e in value.cast<Map<String, dynamic>>())
        SearchResult(
          title: e['name'] as String? ?? '',
          url: e['url'] as String? ?? '',
          snippet: e['snippet'] as String? ?? '',
          content: e['summary'] as String? ?? '',
        ),
    ];
  }

  Future<List<SearchResult>> _exa(String query, int maxResults) async {
    final r = await _dio.post<Map<String, dynamic>>(
      'https://api.exa.ai/search',
      options: Options(headers: {'x-api-key': apiKey}),
      data: {
        'query': query,
        'numResults': maxResults,
        'type': 'auto',
        'contents': {'text': true},
      },
    );
    final results = (r.data?['results'] as List<dynamic>? ?? []);
    return [
      for (final e in results.cast<Map<String, dynamic>>())
        SearchResult(
          title: e['title'] as String? ?? '',
          url: e['url'] as String? ?? '',
          snippet: '',
          content: e['text'] as String? ?? '',
        ),
    ];
  }
}
