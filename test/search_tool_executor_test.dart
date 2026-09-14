import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:expert_chat/domain/tools/search_tool_executor.dart';
import 'package:expert_chat/domain/tools/tool_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _Search extends HttpSearchProvider {
  _Search() : super(backend: SearchBackend.duckduckgo, apiKey: '');
  List<SearchResult> results = [];
  final queries = <String>[];
  final fetched = <String>[];
  Object? error;
  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 8,
    CancelToken? cancelToken,
  }) async {
    queries.add(query);
    if (error != null) throw error!;
    return results.take(maxResults).toList();
  }

  @override
  Future<SearchResult> fetchPage(String url, {CancelToken? cancelToken}) async {
    fetched.add(url);
    if (error != null) throw error!;
    return _page(url);
  }
}

SearchResult _page(String url) => SearchResult(
  title: 'Page',
  url: url,
  content:
      'A complete page with enough source text to preserve the existing minimum body threshold.',
);

Future<SearchToolResult> _run(
  SearchToolExecutor executor, {
  String name = 'web_search',
  String args = '{"query":"test"}',
  List<Citation> citations = const [],
  Set<String> allowed = const {},
  SearchBackend backend = SearchBackend.duckduckgo,
  CancelToken? token,
  List<SearchActivity>? activities,
}) => executor.execute(
  call: ToolCall(index: 0, id: 'call', name: name, argumentsJson: args),
  fallbackSearchQuery: '请问  fallback   topic',
  searchApiKey: 'test-key',
  maxResults: 8,
  backend: backend,
  citations: citations,
  allowedFetchUrls: allowed,
  cancelToken: token ?? CancelToken(),
  onActivity: (activity) => activities?.add(activity),
);

void main() {
  test(
    'search excludes earlier sources and continues their numbering without mutating input',
    () async {
      final source = _Search()
        ..results = [
          _page('https://example.com/old'),
          _page('https://example.com/new'),
        ];
      final engine = ToolEngine(source);
      final executor = SearchToolExecutor(
        createEngine: ({required backend, required apiKey}) => engine,
      );
      final prior = [
        const Citation(index: 1, title: 'Old', url: 'https://example.com/old'),
      ];
      final activities = <SearchActivity>[];
      final result = await _run(
        executor,
        citations: prior,
        activities: activities,
      );
      expect(result.citations.map((c) => c.index), [1, 2]);
      expect(result.citations.map((c) => c.url), [
        'https://example.com/old',
        'https://example.com/new',
      ]);
      expect(result.content, contains('[2] Page'));
      expect(result.content, isNot(contains('https://example.com/old')));
      expect(prior, hasLength(1));
      expect(result.citationsChanged, isTrue);
      expect(() => result.citations.clear(), throwsUnsupportedError);
      expect(activities.first.status, SearchActivityStatus.running);
      expect(activities.last.status, SearchActivityStatus.done);
      expect(activities.first.id, activities.last.id);
    },
  );

  test(
    'malformed or empty query arguments fall back to normalized user text',
    () async {
      final source = _Search();
      final executor = SearchToolExecutor(
        createEngine: ({required backend, required apiKey}) =>
            ToolEngine(source),
      );
      for (final args in ['{', '[]', '{"query":3}', '{"query":"  "}']) {
        final result = await _run(executor, args: args);
        expect(result.content, '没有搜索到与 "fallback topic" 相关的结果。');
        expect(result.error, isNull);
        expect(result.citationsChanged, isFalse);
      }
      await _run(executor, args: '{"query":"请问  model   topic"}');
      expect(source.queries, [
        ...List.filled(4, 'fallback topic'),
        'model topic',
      ]);
    },
  );

  test(
    'invalid and invented fetch URLs fail with a trace before constructing an engine',
    () async {
      final executor = SearchToolExecutor(
        createEngine: ({required backend, required apiKey}) {
          fail('Rejected URL must not construct a service');
        },
      );
      for (final raw in [
        '{',
        '{"url":"http://127.0.0.1/"}',
        '{"url":"https://example.com/other"}',
      ]) {
        final activities = <SearchActivity>[];
        final result = await _run(
          executor,
          name: 'fetch_url',
          args: raw,
          allowed: {
            SearchToolExecutor.fetchUrlKey('https://example.com/allowed'),
          },
          activities: activities,
        );
        expect(result.citationsChanged, isFalse);
        expect(result.error, isNull, reason: '参数拒绝只记录步骤，不新增会话错误');
        expect(activities, hasLength(2));
        expect(activities.first.id, activities.last.id);
        expect(activities.last.kind, SearchActivityKind.fetch);
        expect(activities.last.status, SearchActivityStatus.failed);
        expect(activities.last.resultCount, 0);
        expect(
          result.content,
          anyOf(startsWith('无效的 URL'), startsWith('已拒绝读取')),
        );
      }
    },
  );

  test(
    'allowed fetch preserves its URL and appends citations with a client backend',
    () async {
      final source = _Search();
      final selected = <SearchBackend>[];
      final executor = SearchToolExecutor(
        createEngine: ({required backend, required apiKey}) {
          selected.add(backend);
          expect(apiKey, 'test-key');
          return ToolEngine(source);
        },
      );
      const url = 'https://example.com/page#section';
      final result = await _run(
        executor,
        name: 'fetch_url',
        args: jsonEncode({'url': ' $url '}),
        backend: SearchBackend.provider,
        allowed: {
          SearchToolExecutor.fetchUrlKey('https://EXAMPLE.com/./page#other'),
        },
        citations: const [Citation(index: 1, title: 'Old', url: url)],
      );
      expect(selected, [SearchBackend.duckduckgo]);
      expect(source.fetched, [url]);
      expect(result.citations.map((c) => c.index), [1, 2]);
      expect(result.citations.last.url, url);
      expect(result.content, contains('[2] Page'));
    },
  );

  test(
    'provider failure preserves prior citations and can be retried',
    () async {
      final error = StateError('offline');
      final source = _Search()..error = error;
      final engine = ToolEngine(source);
      final executor = SearchToolExecutor(
        createEngine: ({required backend, required apiKey}) => engine,
      );
      final prior = [
        const Citation(index: 1, title: 'Old', url: 'https://example.com/old'),
      ];
      final failed = await _run(executor, citations: prior);
      expect(failed.error, same(error));
      expect(failed.content, '联网搜索失败：$error');
      expect(failed.citations, prior);
      source.error = null;
      source.results = [_page('https://example.com/new')];
      final retried = await _run(executor, citations: failed.citations);
      expect(retried.error, isNull);
      expect(retried.citations.map((c) => c.index), [1, 2]);
      expect(source.queries, hasLength(2));
    },
  );

  test(
    'search and fetch cancellation return their existing text without an error banner',
    () async {
      final source = _Search();
      final executor = SearchToolExecutor(
        createEngine: ({required backend, required apiKey}) =>
            ToolEngine(source),
      );
      final token = CancelToken()..cancel();
      final search = await _run(executor, token: token);
      final fetch = await _run(
        executor,
        name: 'fetch_url',
        args: '{"url":"https://example.com/"}',
        allowed: {SearchToolExecutor.fetchUrlKey('https://example.com/')},
        token: token,
      );
      expect(search.content, '搜索已取消。');
      expect(fetch.content, '网页读取已取消。');
      expect(search.error, isNull);
      expect(fetch.error, isNull);
      expect(source.queries, isEmpty);
      expect(source.fetched, isEmpty);
    },
  );
}
