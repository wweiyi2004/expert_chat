import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models.dart';
import '../llm/llm_provider.dart';
import 'search_provider.dart';
import 'search_query.dart';
import 'tool_engine.dart';

class SearchToolResult {
  SearchToolResult({
    required this.content,
    required List<Citation> citations,
    this.citationsChanged = false,
    this.error,
  }) : citations = List.unmodifiable(citations);

  final String content;
  final List<Citation> citations;
  final bool citationsChanged;

  /// Only non-cancellation failures should become a scoped UI error.
  final Object? error;
}

/// Executes model search/fetch calls without application state or persistence.
/// Existing ToolEngine instances retain their cache and source formatting.
class SearchToolExecutor {
  const SearchToolExecutor({required this.createEngine});

  final ToolEngine Function({
    required SearchBackend backend,
    required String apiKey,
  })
  createEngine;

  Future<SearchToolResult> execute({
    required ToolCall call,
    required String fallbackSearchQuery,
    required String searchApiKey,
    required int maxResults,
    required SearchBackend backend,
    required List<Citation> citations,
    required Set<String> allowedFetchUrls,
    bool allowPublicFetch = false,
    bool networkAllowed = true,
    required CancelToken cancelToken,
    required SearchActivityListener onActivity,
  }) async {
    final prior = List<Citation>.of(citations);
    final fetching = call.name == ToolEngine.fetchUrlTool.name;
    if (!fetching && call.name != ToolEngine.webSearchTool.name) {
      throw ArgumentError.value(
        call.name,
        'call.name',
        'Not a search/fetch tool',
      );
    }
    final query = fetching
        ? _urlFromArgs(call.argumentsJson)
        : _searchQueryFromArgs(call.argumentsJson, fallbackSearchQuery);

    if (fetching &&
        (!networkAllowed ||
            query == null ||
            (!allowPublicFetch &&
                !allowedFetchUrls.contains(fetchUrlKey(query)) &&
                !prior.any((c) => fetchUrlKey(c.url) == fetchUrlKey(query))))) {
      final activity = SearchActivity(
        kind: SearchActivityKind.fetch,
        query: query ?? 'fetch_url',
      );
      onActivity(activity);
      onActivity(
        activity.copyWith(
          status: SearchActivityStatus.failed,
          resultCount: 0,
          error: query == null ? '无效 URL' : '已拒绝读取',
          items: const [],
        ),
      );
      return SearchToolResult(
        content: !networkAllowed
            ? '本会话已禁止联网检索，未执行。'
            : query == null
            ? '无效的 URL 参数；请提供完整的 http(s) 网址。'
            : '已拒绝读取：fetch_url 只能访问本轮用户提供或搜索结果中的网址。',
        citations: prior,
      );
    }

    try {
      final engine = createEngine(
        backend: fetching && backend.isProviderHosted
            ? SearchBackend.deepseek
            : backend,
        apiKey: searchApiKey,
      );
      final context = fetching
          ? await engine.runFetchUrls(
              [query!],
              startIndex: prior.length + 1,
              onActivity: onActivity,
              cancelToken: cancelToken,
            )
          : await engine.runSearch(
              query!,
              maxResults: maxResults,
              startIndex: prior.length + 1,
              excludeUrls: {for (final c in prior) c.url},
              onActivity: onActivity,
              cancelToken: cancelToken,
            );
      return SearchToolResult(
        content: context.contextText.isNotEmpty
            ? context.contextText
            : fetching
            ? '未能读取网页：$query'
            : '没有搜索到与 "$query" 相关的结果。',
        citations: [...prior, ...context.citations],
        citationsChanged: context.citations.isNotEmpty,
      );
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) {
        return SearchToolResult(
          content: fetching ? '网页读取已取消。' : '搜索已取消。',
          citations: prior,
        );
      }
      return SearchToolResult(
        content: fetching ? '读取网页失败：$error' : '联网搜索失败：$error',
        citations: prior,
        error: error,
      );
    }
  }

  static String _searchQueryFromArgs(String raw, String fallback) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['query'] is String) {
        final query = normalizeSearchQuery(decoded['query'] as String);
        if (query.isNotEmpty) return query;
      }
    } catch (_) {
      // Fall through to the user turn if the model returned malformed JSON.
    }
    return normalizeSearchQuery(fallback);
  }

  static String? _urlFromArgs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['url'] is String) {
        final url = (decoded['url'] as String).trim();
        if (url.isNotEmpty && HttpSearchProvider.isSafeHttpUrl(url)) {
          return url;
        }
      }
    } catch (_) {
      // Malformed JSON from the model.
    }
    return null;
  }

  /// Canonical comparison key shared by normal turns and saved-step retries.
  static String fetchUrlKey(String url) {
    final uri = Uri.parse(url);
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          path: uri.path.isEmpty ? '/' : uri.path,
          fragment: '',
        )
        .normalizePath()
        .toString();
  }
}
