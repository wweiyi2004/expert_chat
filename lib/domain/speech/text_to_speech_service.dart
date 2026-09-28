import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../../data/media_api_config.dart';

export 'text_to_speech_service_stub.dart'
    if (dart.library.io) 'text_to_speech_service_io.dart';

/// The visible lifecycle of a single message being read aloud.
enum TextToSpeechPhase { idle, loading, speaking, error }

class TextToSpeechPlayback {
  const TextToSpeechPlayback({
    this.phase = TextToSpeechPhase.idle,
    this.messageId,
    this.requestId = 0,
    this.errorMessage,
  });

  final TextToSpeechPhase phase;
  final String? messageId;

  /// Monotonically increasing id lets the UI show a repeated failure once for
  /// every new attempt on the same message.
  final int requestId;
  final String? errorMessage;

  bool get isActive =>
      phase == TextToSpeechPhase.loading || phase == TextToSpeechPhase.speaking;

  bool isFor(String id) => messageId == id;
}

/// Values required for one configured cloud TTS request.
class TextToSpeechRequest {
  const TextToSpeechRequest({
    required this.messageId,
    required this.text,
    required this.apiConfig,
    required this.apiKey,
    this.rate = 0.5,
    this.autoEmotion = true,
  });

  final String messageId;
  final String text;
  final MediaApiConfig? apiConfig;
  final String apiKey;

  /// UI rate normalized to the 0.0–1.0 scale and adapted to the selected
  /// cloud TTS protocol before a request is sent.
  final double rate;

  /// When true, each sentence gets an auto-inferred delivery instruction so
  /// long replies change tone with the text (happy / sad / narrative…).
  final bool autoEmotion;
}

/// A read-aloud whose text keeps arriving while it already speaks, so voice
/// conversation mode can start reading a reply before it finishes streaming.
abstract class TextToSpeechStream {
  /// Queues more text; it is cleaned and split into sentences like [speak].
  void append(String text);

  /// No more text follows; playback ends once the queued sentences are read.
  void close();

  /// True once every queued sentence was spoken; false when the stream was
  /// stopped, replaced by another request, or failed. Never errors.
  Future<bool> get done;
}

abstract class TextToSpeechService {
  ValueListenable<TextToSpeechPlayback> get playback;

  /// Starts API synthesis and playback. Starting another request replaces the
  /// earlier one; callers can use [playback] for UI state.
  Future<void> speak(TextToSpeechRequest request);

  /// Starts an incremental read-aloud seeded with [TextToSpeechRequest.text]
  /// (which may be empty). Replaces any earlier request, like [speak].
  TextToSpeechStream startStream(TextToSpeechRequest request);

  Future<void> stop();

  Future<void> dispose();
}

/// Sentence queue behind a [TextToSpeechStream]. Callers append while the
/// owning service's play loop consumes chunks in order.
class SpeechChunkQueue implements TextToSpeechStream {
  SpeechChunkQueue({this.maxChunkLength = 280});

  final int maxChunkLength;
  final List<String> _chunks = [];
  final Completer<bool> _done = Completer<bool>();
  Completer<void>? _waiter;
  bool _closed = false;
  bool _cancelled = false;

  /// Called after new chunks arrive so the service can top up its prefetch.
  VoidCallback? onAppend;

  int get length => _chunks.length;

  String operator [](int index) => _chunks[index];

  /// No further chunks can arrive (closed by the caller, or cancelled).
  bool get isClosed => _closed || _cancelled;

  bool get isCancelled => _cancelled;

  @override
  void append(String text) => addChunks(
    splitTextForSpeech(
      prepareTextForSpeech(text),
      maxChunkLength: maxChunkLength,
      packSentences: false,
    ),
  );

  /// Queues chunks that were already cleaned and split.
  void addChunks(List<String> chunks) {
    if (isClosed || chunks.isEmpty) return;
    _chunks.addAll(chunks);
    _wake();
    onAppend?.call();
  }

  @override
  void close() {
    _closed = true;
    _wake();
  }

  /// Stops accepting text and wakes a waiting play loop; [done] is false.
  void cancel() {
    _cancelled = true;
    _wake();
    finish(false);
  }

  /// Waits until chunk [index] exists or no more chunks can arrive.
  Future<void> waitFor(int index) async {
    while (_chunks.length <= index && !isClosed) {
      await (_waiter ??= Completer<void>()).future;
    }
  }

  /// Settles [done] once; later calls are ignored.
  void finish(bool completed) {
    onAppend = null;
    if (!_done.isCompleted) _done.complete(completed);
  }

  @override
  Future<bool> get done => _done.future;

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }
}

/// Removes markup that is useful on screen but distracting when spoken:
/// URLs, citations, code fences, markdown decoration and table pipes.
String prepareTextForSpeech(String source) {
  var text = source
      .replaceAll(RegExp(r'```[\s\S]*?```'), '（代码内容已省略）')
      .replaceAllMapped(
        RegExp(r'!?\[([^\]]*)\]\([^)]+\)'),
        (match) => match.group(1) ?? '',
      )
      .replaceAll(RegExp(r'<https?://[^>]+>'), '')
      // A URL is often followed directly by full-width punctuation (。，；！？),
      // which is not whitespace, so \S+ would swallow it together with the
      // URL. Full-width marks never occur inside a valid URL, so capture the
      // first one and keep it; the bare-URL pass below handles the rest.
      .replaceAllMapped(
        RegExp(r'https?://\S+?([。，；！？])'),
        (match) => match.group(1) ?? '',
      )
      .replaceAll(RegExp(r'https?://\S+'), '')
      .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+', multiLine: true), '')
      .replaceAll(RegExp(r'\[(?:\d+\s*,?\s*)+\]'), '')
      .replaceAll(RegExp(r'[`*_~]'), '')
      .replaceAll('|', '，');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text;
}

/// Splits a long message into API-safe sentence-sized chunks.
///
/// Each chunk is at most [maxChunkLength] grapheme clusters long.
///
/// When [packSentences] is true (default), adjacent short sentences are merged
/// until the length budget is reached — fewer API calls for bulk synthesis.
/// When false, each sentence is its own chunk (unless it exceeds
/// [maxChunkLength] and must be split). Use false for pipelined playback so
/// one sentence can play while the next ones download.
List<String> splitTextForSpeech(
  String text, {
  int maxChunkLength = 600,
  bool packSentences = true,
}) {
  if (maxChunkLength < 1) return const [];
  final normalized = text.trim();
  if (normalized.isEmpty) return const [];

  final sentences = [
    // The punctuation group is greedy so consecutive marks ('明白了!!')
    // stay with the sentence they close, keeping chunks.join() == text.
    for (final match in RegExp(
      r'[^。！？!?；;\n]+[。！？!?；;]*',
    ).allMatches(normalized))
      match.group(0)?.trim() ?? '',
  ].where((part) => part.isNotEmpty);

  if (!packSentences) {
    return [
      for (final sentence in sentences)
        for (final part in _splitOversizedSpeechPart(sentence, maxChunkLength))
          part,
    ];
  }

  final chunks = <String>[];
  var buffer = '';
  for (final sentence in sentences) {
    for (final part in _splitOversizedSpeechPart(sentence, maxChunkLength)) {
      final combined = '$buffer$part';
      if (buffer.isNotEmpty && combined.characters.length > maxChunkLength) {
        chunks.add(buffer);
        buffer = part;
      } else {
        buffer = combined;
      }
    }
  }
  if (buffer.isNotEmpty) chunks.add(buffer);
  return chunks;
}

List<String> _splitOversizedSpeechPart(String part, int maxChunkLength) {
  final characters = part.characters.toList();
  if (characters.length <= maxChunkLength) return [part];

  final chunks = <String>[];
  var start = 0;
  while (characters.length - start > maxChunkLength) {
    var cut = start + maxChunkLength;
    for (var i = cut - 1; i >= start + (maxChunkLength ~/ 2); i--) {
      if (const {'，', '、', ',', ' ', '：', ':'}.contains(characters[i])) {
        cut = i + 1;
        break;
      }
    }
    final chunk = characters.sublist(start, cut).join().trim();
    if (chunk.isNotEmpty) chunks.add(chunk);
    start = cut;
    while (start < characters.length && characters[start].trim().isEmpty) {
      start++;
    }
  }
  final last = characters.sublist(start).join().trim();
  if (last.isNotEmpty) chunks.add(last);
  return chunks;
}
