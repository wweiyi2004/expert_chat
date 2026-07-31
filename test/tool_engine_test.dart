import 'package:dio/dio.dart' show CancelToken;
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:expert_chat/domain/tools/tool_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Body long enough to clear ToolEngine.minSourceChars (40) so fixtures are
/// not dropped by the thin-body filter.
const _richBody =
    'This body is long enough to pass the minimum source length filter and '
    'to behave like a real search snippet in budget tests.';

class _CountingSearch implements SearchProvider {
  _CountingSearch(this.results);

  final List<SearchResult> results;
  int calls = 0;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 8,
    CancelToken? cancelToken,
  }) async {
    calls++;
    return results;
  }
}

void main() {
  group('ToolEngine search cache', () {
    test('cache key includes excludeUrls and startIndex', () async {
      final search = _CountingSearch(const [
        SearchResult(
          title: 'Hit',
          url: 'https://example.com/hit',
          content: _richBody,
        ),
      ]);
      final engine = ToolEngine(search);

      await engine.runSearch('q', excludeUrls: const {'https://a.com'});
      expect(search.calls, 1);

      // Same query + same excludes → cache hit.
      await engine.runSearch('q', excludeUrls: const {'https://a.com'});
      expect(search.calls, 1);

      // A broader exclude set must re-run the search. With the old key
      // (query + maxResults only) this hit the stale cache and every source
      // stayed excluded — the orchestration loop spun on "没有新的搜索结果"
      // until the TTL expired.
      await engine.runSearch(
        'q',
        excludeUrls: const {'https://a.com', 'https://b.com'},
      );
      expect(search.calls, 2);

      // excludeUrls order must not create a distinct cache entry.
      await engine.runSearch(
        'q',
        excludeUrls: const {'https://b.com', 'https://a.com'},
      );
      expect(search.calls, 2);

      // startIndex participates in the key as well.
      await engine.runSearch(
        'q',
        excludeUrls: const {'https://a.com', 'https://b.com'},
        startIndex: 5,
      );
      expect(search.calls, 3);
    });
  });

  group('ToolEngine search budget', () {
    test('title/URL header lines count against the total budget', () async {
      final body = 'B' * 2039;
      final results = [
        for (var i = 1; i <= 12; i++)
          SearchResult(
            title: 'T' * 100,
            url: 'https://example.com/source-$i',
            content: body,
          ),
      ];
      final engine = ToolEngine(_CountingSearch(results));

      final ctx = await engine.runSearch('q', maxResults: 12);

      // Bodies alone (12 × 2039 = 24468) would only force a clip of the last
      // source; counting the "[n] Title" / "URL:" header lines (plus the
      // blank separator) exhausts the 24000-char budget before the 12th
      // source is reached.
      expect(ctx.citations, hasLength(11));
      expect(ctx.contextText, contains('https://example.com/source-11'));
      expect(ctx.contextText, isNot(contains('https://example.com/source-12')));
    });
  });
}
