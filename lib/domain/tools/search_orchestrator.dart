import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart' show CancelToken, DioException;

import '../../data/models.dart';
import '../llm/llm_provider.dart';
import 'search_query.dart';
import 'tool_engine.dart';

/// Outcome of a brain-orchestrated retrieval pass.
class SearchOrchestration {
  const SearchOrchestration({required this.context, required this.searched});

  /// Merged injectable context; citations are numbered continuously across
  /// every round so they share one numbering space with the final answer.
  final SearchContext context;

  /// False when the planner decided the question needs no web data (auto
  /// mode letting an offline question stay offline).
  final bool searched;

  static const none = SearchOrchestration(
    context: SearchContext(contextText: '', citations: []),
    searched: false,
  );
}

/// Multi-round retrieval for models that cannot call tools themselves
/// (`deepseek-reasoner` and friends): a tool-capable "搜索大脑" model reads the
/// recent conversation, rewrites self-contained queries (so follow-ups like
/// "那它多少钱" search well), runs `web_search` over several rounds, and the
/// merged results are injected into the real model's prompt.
///
/// The planner's own text output is never shown — only its tool calls matter.
class SearchOrchestrator {
  SearchOrchestrator(this._llm, this._engine);

  final LlmProvider _llm;
  final ToolEngine _engine;

  /// Per-round cap on planner-issued queries, so a misbehaving planner cannot
  /// fan out an unbounded number of network requests.
  static const int maxQueriesPerRound = 2;

  static const int _historyMessages = 6;
  static const int _historyCharsPerMessage = 400;
  static const int _userQueryChars = 2000;

  /// Plans and executes retrieval for [userQuery].
  ///
  /// [force] is the "联网·强制" mode: the planner must search at least once,
  /// and if it refuses a direct search of [userQuery] runs as a fallback.
  /// Without [force] (auto mode) the planner may answer `NONE`, yielding
  /// [SearchOrchestration.searched] == false and an empty context.
  Future<SearchOrchestration> run({
    required LlmConfig brainConfig,
    required List<LlmRequestMessage> history,
    required String userQuery,
    required bool force,
    int maxRounds = 3,
    int maxResults = ToolEngine.defaultMaxResults,
    int startIndex = 1,
    SearchActivityListener? onActivity,
    CancelToken? cancelToken,
  }) async {
    final blocks = <String>[];
    final citations = <Citation>[];
    final seenUrls = <String>{};
    var searched = false;
    var index = startIndex;
    var charsBudget = ToolEngine.maxTotalChars;
    Object? lastSearchError;

    final messages = <LlmRequestMessage>[
      LlmRequestMessage(
        role: MessageRole.system,
        content: _plannerPrompt(force: force, maxRounds: maxRounds),
      ),
      ..._clipHistory(history),
      LlmRequestMessage(
        role: MessageRole.user,
        content: _clip(userQuery, _userQueryChars),
      ),
    ];

    try {
      for (var round = 0; round < maxRounds; round++) {
        _throwIfCancelled(cancelToken);
        final turn = await _collect(
          _llm.streamChat(
            config: brainConfig,
            messages: messages,
            tools: const [ToolEngine.webSearchTool],
            cancelToken: cancelToken,
          ),
        );
        if (turn.toolCalls.isEmpty) break; // planner answered NONE / DONE

        messages.add(
          LlmRequestMessage(
            role: MessageRole.assistant,
            content: turn.content,
            toolCalls: turn.toolCalls,
          ),
        );

        var executed = 0;
        for (final call in turn.toolCalls) {
          String result;
          final query = call.name == ToolEngine.webSearchTool.name
              ? _queryFromArgs(call.argumentsJson)
              : null;
          if (call.name != ToolEngine.webSearchTool.name) {
            result = '仅支持 web_search 工具。';
          } else if (query == null) {
            result = '缺少有效的 query 参数。';
          } else if (executed >= maxQueriesPerRound) {
            result = '本轮查询数已达上限，请基于已有结果继续或结束。';
          } else if (charsBudget <= 0) {
            result = '检索预算已用完，请回复 DONE 结束。';
          } else {
            executed++;
            try {
              final ctx = await _engine.runSearch(
                query,
                maxResults: maxResults,
                startIndex: index,
                excludeUrls: seenUrls,
                onActivity: onActivity,
                cancelToken: cancelToken,
              );
              searched = true;
              if (ctx.citations.isEmpty) {
                result = '没有搜索到新的相关结果。可换个关键词，或回复 DONE 结束。';
              } else {
                blocks.add(ctx.contextText);
                citations.addAll(ctx.citations);
                seenUrls.addAll(ctx.citations.map((c) => c.url));
                index += ctx.citations.length;
                charsBudget -= ctx.contextText.length;
                result = ctx.contextText;
              }
            } catch (e) {
              if (_isCancel(e)) rethrow;
              lastSearchError = e;
              result = '搜索失败：$e。可稍后重试其他关键词，或回复 DONE 结束。';
            }
          }
          messages.add(
            LlmRequestMessage(
              role: MessageRole.tool,
              content: result,
              toolCallId: call.id ?? '',
            ),
          );
        }
        if (charsBudget <= 0) break;
      }
    } catch (e) {
      if (_isCancel(e)) rethrow;
      // Planner unavailable (endpoint hiccup, bad model id…): keep whatever
      // was already retrieved; with nothing retrieved degrade to one direct
      // search so "联网" still works at the old single-shot level.
      if (citations.isEmpty) {
        return _directSearch(
          userQuery,
          maxResults: maxResults,
          startIndex: startIndex,
          onActivity: onActivity,
          cancelToken: cancelToken,
        );
      }
    }

    if (force && !searched) {
      // Planner refused despite the explicit "必须搜索" instruction.
      return _directSearch(
        userQuery,
        maxResults: maxResults,
        startIndex: startIndex,
        onActivity: onActivity,
        cancelToken: cancelToken,
      );
    }

    if (citations.isEmpty && lastSearchError != null) {
      // Every attempt hit the backend error (key missing, rate-limited…);
      // surface it like the classic pre-search path instead of silently
      // answering without web data.
      Error.throwWithStackTrace(lastSearchError, StackTrace.current);
    }

    return SearchOrchestration(
      context: SearchContext(
        contextText: blocks.join('\n'),
        citations: List.unmodifiable(citations),
      ),
      searched: searched,
    );
  }

  Future<SearchOrchestration> _directSearch(
    String userQuery, {
    required int maxResults,
    required int startIndex,
    SearchActivityListener? onActivity,
    CancelToken? cancelToken,
  }) async {
    final ctx = await _engine.runSearch(
      normalizeSearchQuery(userQuery),
      maxResults: maxResults,
      startIndex: startIndex,
      onActivity: onActivity,
      cancelToken: cancelToken,
    );
    return SearchOrchestration(context: ctx, searched: true);
  }

  String _plannerPrompt({required bool force, required int maxRounds}) {
    final base = StringBuffer()
      ..writeln('你是对话应用内部的检索规划助手，为另一个回答模型准备联网资料。${ToolEngine.dateLine()}。')
      ..writeln('你的任务不是回答用户，而是判断是否需要联网检索，并在需要时用 web_search 完成检索。')
      ..writeln('规则：')
      ..writeln('1. 涉及实时信息（新闻、价格、版本、赛果、天气）或你不确定的事实时，调用 web_search。')
      ..writeln('2. 关键词必须自包含：把"它/这个"等指代替换成对话中的具体名称；时效性问题补上年份。')
      ..writeln('3. 一次调用只搜一个主题；多个主题分多次调用；每轮最多 $maxQueriesPerRound 次，'
          '最多 $maxRounds 轮。')
      ..writeln('4. 已有结果足以支撑回答时，停止调用工具，仅回复：DONE');
    if (force) {
      base.writeln('5. 用户已强制开启联网：本次必须至少调用一次 web_search，然后才能结束。');
    } else {
      base.writeln('5. 完全不需要联网（闲聊、翻译、写作、纯推理/数学/代码）时，不调用工具，仅回复：NONE');
    }
    base.writeln('除 DONE / NONE 外不要输出其他文本。');
    return base.toString();
  }

  /// Latest turns only, system/tool messages dropped, each clipped — the
  /// planner needs referents ("它"→具体名称), not the whole transcript.
  List<LlmRequestMessage> _clipHistory(List<LlmRequestMessage> history) {
    final relevant = [
      for (final m in history)
        if ((m.role == MessageRole.user || m.role == MessageRole.assistant) &&
            m.content.trim().isNotEmpty)
          m,
    ];
    final tail = relevant.length <= _historyMessages
        ? relevant
        : relevant.sublist(relevant.length - _historyMessages);
    return [
      for (final m in tail)
        LlmRequestMessage(
          role: m.role,
          content: _clip(m.content, _historyCharsPerMessage),
        ),
    ];
  }

  static String _clip(String value, int maxChars) =>
      value.characters.length <= maxChars
      ? value
      : '${value.characters.take(maxChars)}…';

  Future<({String content, List<ToolCall> toolCalls})> _collect(
    Stream<ChatChunk> stream,
  ) async {
    final drafts = <int, ToolCallDraft>{};
    final content = StringBuffer();
    await for (final chunk in stream) {
      final delta = chunk.contentDelta;
      if (delta != null && delta.isNotEmpty) content.write(delta);
      for (final call in chunk.toolCalls ?? const <ToolCall>[]) {
        (drafts[call.index] ??= ToolCallDraft(call.index)).merge(call);
      }
    }
    return (
      content: content.toString(),
      toolCalls: ToolCallDraft.finalize(drafts),
    );
  }

  String? _queryFromArgs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['query'] is String) {
        final query = normalizeSearchQuery(decoded['query'] as String);
        if (query.isNotEmpty) return query;
      }
    } catch (_) {
      // Malformed planner JSON — treated as an invalid call below.
    }
    return null;
  }

  static bool _isCancel(Object e) =>
      e is DioException && CancelToken.isCancel(e);

  static void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled ?? false) {
      throw cancelToken!.cancelError!;
    }
  }
}
