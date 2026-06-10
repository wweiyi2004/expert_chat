import 'package:characters/characters.dart';
import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

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
enum SearchBackend { duckduckgo, tavily, bocha, exa }

extension SearchBackendInfo on SearchBackend {
  String get label => switch (this) {
    SearchBackend.duckduckgo => 'DuckDuckGo（免费，无 Key）',
    SearchBackend.tavily => 'Tavily',
    SearchBackend.bocha => '博查 Bocha（中文）',
    SearchBackend.exa => 'Exa',
  };

  String get wire => name;

  bool get requiresApiKey => switch (this) {
    SearchBackend.duckduckgo => false,
    SearchBackend.tavily || SearchBackend.bocha || SearchBackend.exa => true,
  };

  static SearchBackend fromWire(String? v) => SearchBackend.values.firstWhere(
    (b) => b.name == v,
    orElse: () => SearchBackend.duckduckgo,
  );
}

/// Abstraction over a search API. Native/desktop fetch directly; on Web these
/// calls are CORS-gated (handled by the caller).
abstract class SearchProvider {
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 5,
    CancelToken? cancelToken,
  });
}

/// Thrown when the keyless DuckDuckGo backend yields no usable results. A real
/// DDG query almost always returns links, so an empty parse means the free HTML
/// endpoint was rate-limited / blocked or changed layout — NOT a genuine
/// zero-result query. Surfaced so the user can switch to a keyed backend.
class SearchUnavailableException implements Exception {
  const SearchUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Dispatches to the configured backend. Throws a human-readable [Exception]
/// on failure so the chat layer can surface it.
class HttpSearchProvider implements SearchProvider {
  HttpSearchProvider({required this.backend, required this.apiKey, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );

  final SearchBackend backend;
  final String apiKey;
  final Dio _dio;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 5,
    CancelToken? cancelToken,
  }) async {
    if (backend.requiresApiKey && apiKey.trim().isEmpty) {
      throw Exception('未配置联网搜索的 API Key，请在设置中填写。');
    }
    try {
      return switch (backend) {
        SearchBackend.duckduckgo =>
          await _duckduckgo(query, maxResults, cancelToken),
        SearchBackend.tavily => await _tavily(query, maxResults, cancelToken),
        SearchBackend.bocha => await _bocha(query, maxResults, cancelToken),
        SearchBackend.exa => await _exa(query, maxResults, cancelToken),
      };
    } on DioException catch (e) {
      // Let cancellations (stop button) propagate as-is — they're not errors.
      if (CancelToken.isCancel(e)) rethrow;
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw Exception('搜索鉴权失败（$status）：请检查搜索 API Key。');
      }
      throw Exception('联网搜索失败：${e.message ?? e.type.name}');
    }
  }

  Future<List<SearchResult>> _duckduckgo(
    String query,
    int maxResults,
    CancelToken? cancelToken,
  ) async {
    final hits = await _duckduckgoHits(query, maxResults, cancelToken);
    if (hits.isEmpty) {
      // Both the html and lite endpoints parsed to zero links — treat as the
      // backend being unavailable rather than silently returning no sources.
      throw const SearchUnavailableException(
        'DuckDuckGo 免费搜索暂不可用（可能被限流或页面结构变动）。'
        '请在设置中改用 Tavily / Exa / 博查 等带 API Key 的搜索后端。',
      );
    }

    final enriched = await Future.wait([
      for (final hit in hits) _withFetchedContent(hit, cancelToken),
    ]);
    return enriched;
  }

  static const _ddgEndpoints = [
    'https://html.duckduckgo.com/html/',
    'https://lite.duckduckgo.com/lite/',
  ];

  Future<List<SearchResult>> _duckduckgoHits(
    String query,
    int maxResults,
    CancelToken? cancelToken,
  ) async {
    // DDG's HTML form submits via POST; POSTing is markedly less likely to be
    // rate-limited / served a challenge page than a bare GET — the usual reason
    // the free endpoint intermittently returns 200 with zero parseable links.
    // Try POST on both endpoints first, then (after a short back-off) GET, so a
    // transient block on one method/host still has a chance to recover.
    for (var attempt = 0; attempt < 2; attempt++) {
      final usePost = attempt == 0;
      for (final url in _ddgEndpoints) {
        final body = await _ddgFetch(
          url,
          query,
          post: usePost,
          cancelToken: cancelToken,
        );
        final out = _parseDuckDuckGoResults(body, maxResults);
        if (out.isNotEmpty) return out;
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    return const [];
  }

  Future<String> _ddgFetch(
    String url,
    String query, {
    required bool post,
    CancelToken? cancelToken,
  }) async {
    final options = Options(
      responseType: ResponseType.plain,
      headers: _browserHeaders,
      contentType: post ? Headers.formUrlEncodedContentType : null,
    );
    final r = post
        ? await _dio.post<String>(
            url,
            data: {'q': query},
            options: options,
            cancelToken: cancelToken,
          )
        : await _dio.get<String>(
            url,
            queryParameters: {'q': query},
            options: options,
            cancelToken: cancelToken,
          );
    return r.data ?? '';
  }

  List<SearchResult> _parseDuckDuckGoResults(String html, int maxResults) {
    final doc = html_parser.parse(html);
    final out = <SearchResult>[];
    final seen = <String>{};

    final links = [
      ...doc.querySelectorAll('a.result__a, a.result-link'),
      if (doc.querySelectorAll('a.result__a, a.result-link').isEmpty)
        ...doc.querySelectorAll('a[href*="/l/?uddg="], a[href*="uddg="]'),
    ];

    for (final link in links) {
      final href = _normalizeDuckDuckGoUrl(link.attributes['href'] ?? '');
      if (!_isHttpUrl(href) || !seen.add(href)) continue;
      final result = _closestResult(link);
      final title = _cleanText(link.text);
      final snippet = _cleanText(
        result?.querySelector('.result__snippet')?.text ??
            result?.querySelector('.result__body')?.text ??
            '',
      );
      out.add(SearchResult(title: title, url: href, snippet: snippet));
      if (out.length >= maxResults) break;
    }

    return out;
  }

  Future<SearchResult> _withFetchedContent(
    SearchResult hit,
    CancelToken? cancelToken,
  ) async {
    final content = await _fetchReadableText(hit.url, cancelToken);
    return SearchResult(
      title: hit.title,
      url: hit.url,
      snippet: hit.snippet,
      content: content,
    );
  }

  Future<String> _fetchReadableText(String url, CancelToken? cancelToken) async {
    try {
      final r = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: _browserHeaders,
          validateStatus: (status) => status != null && status < 500,
        ),
        cancelToken: cancelToken,
      );
      if ((r.statusCode ?? 0) >= 400) return '';
      final raw = r.data ?? '';
      if (raw.trim().isEmpty) return '';

      final contentType = r.headers.value('content-type')?.toLowerCase() ?? '';
      final looksHtml =
          contentType.contains('text/html') ||
          contentType.contains('application/xhtml') ||
          raw.trimLeft().startsWith('<!doctype') ||
          raw.trimLeft().startsWith('<html');
      if (!looksHtml) {
        if (contentType.startsWith('text/') ||
            contentType.contains('application/json')) {
          return _clip(_cleanText(raw), 10000);
        }
        return '';
      }

      final doc = html_parser.parse(raw);
      for (final selector in const [
        'script',
        'style',
        'noscript',
        'nav',
        'footer',
        'header',
        'aside',
        'svg',
        'form',
      ]) {
        for (final node in doc.querySelectorAll(selector)) {
          node.remove();
        }
      }

      final candidates = [
        doc.querySelector('article'),
        doc.querySelector('main'),
        doc.querySelector('[role="main"]'),
        doc.querySelector('#content'),
        doc.querySelector('.content'),
        doc.body,
      ].whereType<dom.Element>();

      var best = '';
      for (final candidate in candidates) {
        final text = _cleanText(candidate.text);
        if (text.length > best.length) best = text;
      }
      return _clip(best, 10000);
    } catch (_) {
      return '';
    }
  }

  Future<List<SearchResult>> _tavily(
    String query,
    int maxResults,
    CancelToken? cancelToken,
  ) async {
    final r = await _dio.post<Map<String, dynamic>>(
      'https://api.tavily.com/search',
      options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
      cancelToken: cancelToken,
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

  Future<List<SearchResult>> _bocha(
    String query,
    int maxResults,
    CancelToken? cancelToken,
  ) async {
    final r = await _dio.post<Map<String, dynamic>>(
      'https://api.bochaai.com/v1/web-search',
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
      ),
      cancelToken: cancelToken,
      data: {
        'query': query,
        'count': maxResults,
        'summary': true,
        'freshness': 'noLimit',
      },
    );
    final value =
        (r.data?['data']?['webPages']?['value'] as List<dynamic>? ?? []);
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

  Future<List<SearchResult>> _exa(
    String query,
    int maxResults,
    CancelToken? cancelToken,
  ) async {
    final r = await _dio.post<Map<String, dynamic>>(
      'https://api.exa.ai/search',
      options: Options(headers: {'x-api-key': apiKey}),
      cancelToken: cancelToken,
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

  Map<String, String> get _browserHeaders => const {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,'
        'application/json;q=0.8,*/*;q=0.7',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.7',
  };

  dom.Element? _closestResult(dom.Element link) {
    dom.Node? node = link;
    while (node is dom.Element) {
      final classes = node.classes;
      if (classes.contains('result') ||
          classes.contains('web-result') ||
          classes.any((c) => c.startsWith('result__'))) {
        return node;
      }
      node = node.parent;
    }
    return null;
  }

  String _normalizeDuckDuckGoUrl(String href) {
    var raw = href.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('//')) raw = 'https:$raw';
    if (raw.startsWith('/')) raw = 'https://duckduckgo.com$raw';

    final uri = Uri.tryParse(raw);
    final uddg = uri?.queryParameters['uddg'];
    if (uddg != null && uddg.isNotEmpty) return uddg;
    return raw;
  }

  bool _isHttpUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  String _cleanText(String value) => value
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n')
      .trim();

  /// Grapheme-aware clip so the cut can't split an emoji/surrogate pair.
  String _clip(String value, int maxChars) =>
      value.length > maxChars ? value.characters.take(maxChars).toString() : value;
}
