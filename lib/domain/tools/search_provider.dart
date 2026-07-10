import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'pinned_page_client_stub.dart'
    if (dart.library.io) 'pinned_page_client_io.dart';

typedef HostResolver = Future<List<String>> Function(String host);

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
  HttpSearchProvider({
    required this.backend,
    required this.apiKey,
    Dio? dio,
    Dio? pageDio,
    HostResolver? hostResolver,
  }) : _dio = dio ?? Dio(_httpOptions),
       _pageClient = PinnedPageClient(dio: pageDio, options: _httpOptions) {
    _hostResolver = hostResolver ?? _pageClient.resolveHost;
  }

  final SearchBackend backend;
  final String apiKey;
  final Dio _dio;
  final PinnedPageClient _pageClient;
  late final HostResolver _hostResolver;

  static BaseOptions get _httpOptions => BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
  );

  /// Never ask a backend for an unbounded number of results. It also bounds
  /// the amount of third-party page fetching the free DDG path can trigger.
  static const _maxSearchResults = 8;

  /// Article bodies are only supplemental context; a multi-megabyte document
  /// should not be downloaded into the app just to extract a short snippet.
  static const _maxPageBytes = 1024 * 1024;
  static const _maxConcurrentPageFetches = 2;
  static const _pageReadIdleTimeout = Duration(seconds: 15);

  /// Resolves and validates a page URL without issuing an HTTP request.
  /// Exposed so security-sensitive URL policy can be regression-tested.
  Future<bool> isSafeFetchUrl(String url, {CancelToken? cancelToken}) async =>
      await _validateFetchTarget(url, cancelToken) != null;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 5,
    CancelToken? cancelToken,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];
    final boundedMaxResults = maxResults.clamp(1, _maxSearchResults).toInt();
    if (backend.requiresApiKey && apiKey.trim().isEmpty) {
      throw Exception('未配置联网搜索的 API Key，请在设置中填写。');
    }
    try {
      return switch (backend) {
        SearchBackend.duckduckgo => await _duckduckgo(
          normalizedQuery,
          boundedMaxResults,
          cancelToken,
        ),
        SearchBackend.tavily => await _tavily(
          normalizedQuery,
          boundedMaxResults,
          cancelToken,
        ),
        SearchBackend.bocha => await _bocha(
          normalizedQuery,
          boundedMaxResults,
          cancelToken,
        ),
        SearchBackend.exa => await _exa(
          normalizedQuery,
          boundedMaxResults,
          cancelToken,
        ),
      };
    } on DioException catch (e) {
      // Let cancellations (stop button) propagate as-is — they're not errors.
      if (CancelToken.isCancel(e)) rethrow;
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw Exception('搜索鉴权失败（$status）：请检查搜索 API Key。');
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw Exception('联网搜索超时：请检查网络或稍后重试。');
      }
      if (e.type == DioExceptionType.connectionError) {
        throw Exception('联网搜索连接失败：请检查网络后重试。');
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

    return _fetchContentsWithLimit(hits, cancelToken);
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
        try {
          final body = await _ddgFetch(
            url,
            query,
            post: usePost,
            cancelToken: cancelToken,
          );
          final out = _parseDuckDuckGoResults(body, maxResults);
          if (out.isNotEmpty) return out;
        } on DioException catch (e) {
          // A blocked/failed DDG endpoint must not prevent trying its sibling
          // endpoint or the alternate HTTP method. Cancellation is the one
          // exception: stop should end immediately.
          if (CancelToken.isCancel(e)) rethrow;
        }
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (cancelToken?.isCancelled ?? false) {
          throw cancelToken!.cancelError!;
        }
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
      if (!isSafeHttpUrl(href) || !seen.add(href)) continue;
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

  Future<List<SearchResult>> _fetchContentsWithLimit(
    List<SearchResult> hits,
    CancelToken? cancelToken,
  ) async {
    if (hits.isEmpty) return const [];

    final enriched = List<SearchResult?>.filled(hits.length, null);
    var next = 0;

    Future<void> worker() async {
      while (next < hits.length) {
        final index = next++;
        enriched[index] = await _withFetchedContent(hits[index], cancelToken);
      }
    }

    final workers = <Future<void>>[];
    for (var i = 0; i < _maxConcurrentPageFetches && i < hits.length; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);
    return [for (final hit in enriched) hit!];
  }

  Future<String> _fetchReadableText(
    String url,
    CancelToken? cancelToken, {
    int redirectsRemaining = 3,
  }) async {
    try {
      final target = await _validateFetchTarget(url, cancelToken);
      if (target == null) return '';
      _pageClient.pinHost(target.host, target.addresses);
      final r = await _pageClient.dio.get<ResponseBody>(
        target.uri.toString(),
        options: Options(
          responseType: ResponseType.stream,
          headers: _browserHeaders,
          validateStatus: (status) => status != null && status < 500,
          followRedirects: false,
          maxRedirects: 0,
        ),
        cancelToken: cancelToken,
      );
      final status = r.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        if (redirectsRemaining <= 0) return '';
        final location = r.headers.value('location');
        final nextUrl = location == null
            ? null
            : target.uri.resolve(location).toString();
        if (nextUrl == null) return '';
        return _fetchReadableText(
          nextUrl,
          cancelToken,
          redirectsRemaining: redirectsRemaining - 1,
        );
      }
      if (status >= 400) return '';
      final contentLength = int.tryParse(
        r.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (contentLength != null && contentLength > _maxPageBytes) return '';

      final body = r.data;
      if (body == null) return '';
      final bytes = <int>[];
      var byteCount = 0;
      await for (final chunk in body.stream.timeout(_pageReadIdleTimeout)) {
        if (cancelToken?.isCancelled ?? false) {
          throw cancelToken!.cancelError!;
        }
        byteCount += chunk.length;
        if (byteCount > _maxPageBytes) return '';
        bytes.addAll(chunk);
      }

      final raw = utf8.decode(bytes, allowMalformed: true);
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
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      return '';
    } catch (_) {
      return '';
    }
  }

  Future<_ValidatedFetchTarget?> _validateFetchTarget(
    String url,
    CancelToken? cancelToken,
  ) async {
    if (!isSafeHttpUrl(url)) return null;
    _throwIfCancelled(cancelToken);

    final uri = Uri.parse(url);
    final host = uri.host.toLowerCase();
    final literalAddress = _safeCanonicalIpAddress(host);
    if (literalAddress != null) {
      return _ValidatedFetchTarget(uri, host, [literalAddress]);
    }

    final resolved = await _awaitWithCancellation(
      _hostResolver(host),
      cancelToken,
    );
    _throwIfCancelled(cancelToken);
    if (resolved.isEmpty) return null;

    final addresses = <String>{};
    for (final address in resolved) {
      final canonical = _safeCanonicalIpAddress(address);
      if (canonical == null) return null;
      addresses.add(canonical);
    }
    if (addresses.isEmpty) return null;
    return _ValidatedFetchTarget(uri, host, addresses.toList(growable: false));
  }

  static Future<T> _awaitWithCancellation<T>(
    Future<T> operation,
    CancelToken? cancelToken,
  ) {
    if (cancelToken == null) return operation;
    _throwIfCancelled(cancelToken);
    return Future.any<T>([
      operation,
      cancelToken.whenCancel.then<T>((error) => throw error),
    ]);
  }

  static void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled ?? false) {
      throw cancelToken!.cancelError!;
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

  /// Returns false for malformed/non-web URLs and local/private literals.
  /// Hostnames still require [isSafeFetchUrl], which validates every DNS answer.
  static bool isSafeHttpUrl(String url) {
    final Uri uri;
    try {
      uri = Uri.parse(url);
      uri.port;
    } on FormatException {
      return false;
    }

    final host = uri.host.toLowerCase();
    if (uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        host.endsWith('.') ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.contains('%')) {
      return false;
    }

    final ipv4 = _parseCanonicalIpv4(host);
    if (ipv4 != null) return !_isUnsafeIpv4(ipv4);
    if (RegExp(r'^[0-9.]+$').hasMatch(host) ||
        RegExp(
          r'^(?:0x[0-9a-f]+|[0-9]+)(?:\.(?:0x[0-9a-f]+|[0-9]+))*$',
        ).hasMatch(host)) {
      return false;
    }

    final ipv6 = _parseIpv6(host);
    if (ipv6 != null) return !_isUnsafeIpv6(ipv6);
    if (host.contains(':')) return false;

    return host.length <= 253 &&
        host
            .split('.')
            .every(
              (label) =>
                  label.isNotEmpty &&
                  label.length <= 63 &&
                  RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
            );
  }

  static List<int>? _parseCanonicalIpv4(String host) {
    final octets = host.split('.');
    if (octets.length != 4) return null;
    final values = <int>[];
    for (final octet in octets) {
      if (octet.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(octet)) {
        return null;
      }
      final value = int.tryParse(octet);
      if (value == null || value > 255 || value.toString() != octet) {
        return null;
      }
      values.add(value);
    }
    return values;
  }

  static bool _isUnsafeIpv4(List<int> values) {
    final a = values[0];
    final b = values[1];
    // RFC 1918, loopback, link-local, shared/private-use and non-unicast
    // blocks. Documentation/benchmark ranges are also never useful sources.
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 192 && b == 0) ||
        (a == 192 && b == 2) ||
        (a == 198 && (b == 18 || b == 19 || b == 51)) ||
        (a == 203 && b == 0) ||
        a >= 224;
  }

  static List<int>? _parseIpv6(String host) {
    if (!host.contains(':') || host.contains('%')) return null;
    var normalized = host.toLowerCase();
    final ipv4TailIndex = normalized.lastIndexOf(':');
    if (normalized.substring(ipv4TailIndex + 1).contains('.')) {
      final ipv4 = _parseCanonicalIpv4(normalized.substring(ipv4TailIndex + 1));
      if (ipv4 == null) return null;
      normalized =
          '${normalized.substring(0, ipv4TailIndex)}:'
          '${(ipv4[0] << 8 | ipv4[1]).toRadixString(16)}:'
          '${(ipv4[2] << 8 | ipv4[3]).toRadixString(16)}';
    }

    final compression = normalized.indexOf('::');
    if (compression != normalized.lastIndexOf('::')) return null;
    final hasCompression = compression >= 0;
    final sides = hasCompression ? normalized.split('::') : [normalized];
    final left = sides.first.isEmpty ? <String>[] : sides.first.split(':');
    final right = !hasCompression || sides.last.isEmpty
        ? <String>[]
        : sides.last.split(':');
    final groups = [...left, ...right];
    if (groups.any(
          (group) =>
              group.isEmpty ||
              group.length > 4 ||
              !RegExp(r'^[0-9a-f]+$').hasMatch(group),
        ) ||
        (hasCompression ? groups.length >= 8 : groups.length != 8)) {
      return null;
    }

    final missing = 8 - groups.length;
    return [
      ...left.map((group) => int.parse(group, radix: 16)),
      if (hasCompression) ...List<int>.filled(missing, 0),
      ...right.map((group) => int.parse(group, radix: 16)),
    ];
  }

  static bool _isUnsafeIpv6(List<int> groups) {
    final first = groups[0];
    final allZero = groups.every((group) => group == 0);
    final loopback =
        groups.take(7).every((group) => group == 0) && groups[7] == 1;
    final ipv4Mapped =
        groups.take(5).every((group) => group == 0) && groups[5] == 0xffff;
    return allZero ||
        loopback ||
        ipv4Mapped ||
        first & 0xfe00 == 0xfc00 ||
        first & 0xffc0 == 0xfe80 ||
        first & 0xffc0 == 0xfec0 ||
        first & 0xff00 == 0xff00 ||
        (first == 0x2001 &&
            (groups[1] == 0 || groups[1] == 2 || groups[1] == 0x0db8)) ||
        first == 0x2002;
  }

  static String? _safeCanonicalIpAddress(String address) {
    final host = address.toLowerCase();
    final ipv4 = _parseCanonicalIpv4(host);
    if (ipv4 != null) {
      return _isUnsafeIpv4(ipv4) ? null : ipv4.join('.');
    }
    final ipv6 = _parseIpv6(host);
    if (ipv6 == null || _isUnsafeIpv6(ipv6)) return null;
    return host;
  }

  String _cleanText(String value) => value
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n')
      .trim();

  /// Grapheme-aware clip so the cut can't split an emoji/surrogate pair.
  String _clip(String value, int maxChars) => value.length > maxChars
      ? value.characters.take(maxChars).toString()
      : value;
}

class _ValidatedFetchTarget {
  const _ValidatedFetchTarget(this.uri, this.host, this.addresses);

  final Uri uri;
  final String host;
  final List<String> addresses;
}
