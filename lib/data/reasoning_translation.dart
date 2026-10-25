import 'dart:convert';
import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import '../domain/llm/llm_provider.dart';

const reasoningTranslationPromptVersion = 'zh-display-v1';
final reasoningProtectedPattern = RegExp(
  r'```(?:[\s\S]*?```|[\s\S]*$)|~~~(?:[\s\S]*?~~~|[\s\S]*$)|\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)|`[^`\n]+`|\$[^$\n]+\$',
);

String reasoningTranslationCacheKey(String source, LlmConfig config) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          reasoningTranslationPromptVersion,
          'zh-CN',
          config.profileId,
          config.baseUrl,
          config.apiFormat.name,
          config.authMode,
          config.model,
          source,
        ]),
      ),
    )
    .toString();

/// Uses committed UTF-16 source offsets, but never cuts a grapheme or a known
/// code/math span. An oversized protected block is passed through unchanged.
int nextReasoningTranslationEnd(
  String source,
  int start, {
  required bool flushTail,
  bool sourceComplete = true,
}) {
  if (start >= source.length) return start;
  var end = start;
  for (final char in source.substring(start).characters) {
    if (end > start && end - start + char.length > 1500) break;
    end += char.length;
  }
  final paragraph = source.indexOf(
    '\n\n',
    start + (source.length - start >= 300 ? 300 : 0),
  );
  if (paragraph >= start + 300 && paragraph + 2 <= end) end = paragraph + 2;
  if (end == source.length &&
      !flushTail &&
      end - start < 1500 &&
      paragraph < 0) {
    return start;
  }
  for (final span in reasoningProtectedPattern.allMatches(source)) {
    if (span.start < end && span.end > end) {
      end = span.start > start ? span.start : span.end;
      break;
    }
  }
  // Do not send an unfinished fenced block while its source is still streaming.
  if (!flushTail) {
    final tail = source.substring(start, end);
    for (final fence in ['```', '~~~']) {
      final matches = RegExp(RegExp.escape(fence)).allMatches(tail).toList();
      if (matches.length.isOdd) end = start + matches.last.start;
    }
  }
  if (!sourceComplete) {
    final unfinished = unfinishedReasoningProtectedStart(source);
    if (unfinished != null && end > unfinished) {
      end = unfinished.clamp(start, end);
    }
  }
  return end;
}

/// Find an unterminated code/math span without interpreting delimiters inside
/// already protected spans. Idle text is not proof that a streamed span ended.
int? unfinishedReasoningProtectedStart(String source) {
  for (var i = 0; i < source.length; i++) {
    if (i > 0 && source[i - 1] == r'\') continue;
    String? opening, closing;
    for (final pair in const [
      ('```', '```'),
      ('~~~', '~~~'),
      (r'$$', r'$$'),
      (r'\[', r'\]'),
      (r'\(', r'\)'),
      ('`', '`'),
      (r'$', r'$'),
    ]) {
      if (source.startsWith(pair.$1, i)) {
        opening = pair.$1;
        closing = pair.$2;
        break;
      }
    }
    if (opening == null) continue;
    var end = source.indexOf(closing!, i + opening.length);
    while (end > 0 && source[end - 1] == r'\') {
      end = source.indexOf(closing, end + closing.length);
    }
    if (end < 0) return i;
    i = end + closing.length - 1;
  }
  return null;
}

class ReasoningTranslationState {
  const ReasoningTranslationState({
    this.enabled = false,
    this.isRunning = false,
    this.error,
    this.modelChoice = '',
    this.actualModel = '',
    this.sources = const [],
    this.translatedSegments = const {},
    this.translatedSourceLengths = const {},
    this.requestCount = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.reportedUsageCount = 0,
    this.cost,
    this.currency,
  });
  final bool enabled, isRunning;
  final String? error;
  final String modelChoice, actualModel;
  final List<String> sources;
  final Map<int, String> translatedSegments;
  final Map<int, int> translatedSourceLengths;
  final int requestCount, inputTokens, outputTokens;
  final int reportedUsageCount;
  final double? cost;
  final String? currency;

  String? textFor(int index, String exactSource) {
    if (index >= sources.length ||
        sources[index] != exactSource ||
        !translatedSegments.containsKey(index)) {
      return null;
    }
    return '${translatedSegments[index]}${exactSource.substring(translatedSourceLengths[index] ?? 0)}';
  }
}

class ProtectedReasoningText {
  ProtectedReasoningText(String source) {
    // Nonce derives from the actual source so pre-existing placeholders cannot
    // be mistaken for one supplied by this translation request.
    final salt = sha256
        .convert(utf8.encode(source))
        .toString()
        .substring(0, 12);
    text = source.replaceAllMapped(reasoningProtectedPattern, (match) {
      final marker = '⟦EC_${salt}_${originals.length}⟧';
      originals[marker] = match[0]!;
      return marker;
    });
  }
  late final String text;
  final originals = <String, String>{};
  String restore(String translated) {
    var result = translated;
    for (final entry in originals.entries) {
      if (RegExp(RegExp.escape(entry.key)).allMatches(result).length != 1) {
        throw StateError('翻译未完整保留公式或代码，已保留原文');
      }
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }
}
