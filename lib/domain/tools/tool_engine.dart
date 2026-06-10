import 'package:characters/characters.dart';
import 'package:dio/dio.dart' show CancelToken;

import '../../data/models.dart';
import '../llm/llm_provider.dart';
import 'search_provider.dart';

/// Result of a web-search step: the context block to inject into the prompt and
/// the citations to attach to the assistant message.
class SearchContext {
  const SearchContext({required this.contextText, required this.citations});

  final String contextText;
  final List<Citation> citations;

  bool get isEmpty => citations.isEmpty;
}

/// Orchestrates the "智能联网" flow. Because `deepseek-reasoner` (and other
/// reasoning models) cannot use function calling, search is run as an explicit
/// pre-step: discover sources → inject as context → let the model answer with
/// `[n]` citations. This works uniformly for chat and reasoner models.
class ToolEngine {
  ToolEngine(this._search);

  final SearchProvider _search;

  /// Per-source character cap, to protect the context window.
  static const int _perSourceChars = 2000;

  /// The OpenAI-format tool spec (used if a future agentic loop is added for
  /// function-calling-capable models).
  static const webSearchTool = ToolSpec(
    name: 'web_search',
    description: '搜索互联网以获取实时或事实性信息。返回相关网页的标题、链接与摘要。',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '搜索关键词'},
      },
      'required': ['query'],
    },
  );

  /// Runs a search for [query] and returns an injectable context + citations.
  /// Returns an empty [SearchContext] when there are no hits.
  Future<SearchContext> runSearch(
    String query, {
    int maxResults = 5,
    int startIndex = 1,
    CancelToken? cancelToken,
  }) async {
    final results = await _search.search(
      query,
      maxResults: maxResults,
      cancelToken: cancelToken,
    );
    if (results.isEmpty) {
      return const SearchContext(contextText: '', citations: []);
    }

    final citations = <Citation>[];
    final buffer = StringBuffer()
      ..writeln('以下是联网搜索的结果。请基于这些信息回答用户问题，并在引用处用 [编号] 标注来源（例如 [1]）：')
      ..writeln();

    var index = startIndex;
    for (final r in results) {
      if (r.url.trim().isEmpty) continue;
      final text = r.bestText;
      // Grapheme-aware clip so the cut can't split an emoji/surrogate pair.
      final clipped = text.length > _perSourceChars
          ? '${text.characters.take(_perSourceChars)}…'
          : text;
      buffer
        ..writeln('[$index] ${r.title}')
        ..writeln('URL: ${r.url}')
        ..writeln(clipped)
        ..writeln();
      citations.add(
        Citation(
          index: index,
          title: r.title.isEmpty ? r.url : r.title,
          url: r.url,
          snippet: r.snippet,
        ),
      );
      index++;
    }

    if (citations.isEmpty) {
      return const SearchContext(contextText: '', citations: []);
    }
    return SearchContext(contextText: buffer.toString(), citations: citations);
  }
}
