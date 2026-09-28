import 'package:characters/characters.dart';

/// Cuts a streaming assistant reply into sentences that are safe to read
/// aloud before the reply has finished.
///
/// Feed it the whole visible answer each time it grows. Only text up to the
/// last complete sentence is released, and nothing inside an unclosed code
/// fence, so a half-written fence is never read as code. When the answer is
/// replaced (a tool round clears it, or a fallback rewrites it) the read
/// position restarts at the new text instead of skipping or repeating it.
class SentenceStreamer {
  /// Past this many characters without a sentence end, a comma-like mark
  /// also ends a piece so long run-on sentences do not stall the speaker.
  static const int softBreakAfter = 120;

  static const _terminators = '。！？!?；;\n';
  static const _softBreaks = '，,、：:';
  static const _closers = '”’」』）)"\'';

  String _consumed = '';
  String _last = '';

  /// Characters of the current answer already released.
  int get offset => _consumed.length;

  /// Returns sentences completed since the previous call.
  List<String> update(String content) {
    final sentences = <String>[];
    final diverged = !content.startsWith(_consumed);
    final shrank = content.trimRight().length < _last.trimRight().length;
    if (diverged || shrank) {
      // Replaced: release what the old answer had finished but was still
      // held back (e.g. "我先查一下。" right before a tool round cleared it).
      final tail = _last.startsWith(_consumed)
          ? _last.substring(_consumed.length)
          : '';
      if (tail.trim().isNotEmpty &&
          !_fenceOpen(_last, _last.length) &&
          _terminators.contains(tail.trimRight().characters.last)) {
        sentences.add(tail);
      }
      // Only restart when the new text no longer extends what was read.
      if (diverged) _consumed = '';
    }
    _last = content;
    var start = _consumed.length;
    var inFence = _fenceOpen(content, start);
    var i = start;
    while (i < content.length) {
      if (content.startsWith('```', i)) {
        inFence = !inFence;
        i += 3;
        continue;
      }
      if (!inFence && _endsSentence(content, i, i - start)) {
        var end = i + 1;
        while (end < content.length &&
            (_closers.contains(content[end]) ||
                (content[end] != '\n' &&
                    _terminators.contains(content[end])))) {
          end++;
        }
        // "好的！" may still grow into "好的！！”"; wait for the next delta.
        if (end == content.length && content[i] != '\n') break;
        final sentence = content.substring(start, end);
        if (sentence.trim().isNotEmpty) sentences.add(sentence);
        start = end;
        i = end;
        continue;
      }
      i++;
    }
    _consumed = content.substring(0, start);
    return sentences;
  }

  /// Releases everything left once the reply is complete.
  List<String> finish(String content) {
    final sentences = update(content);
    var rest = content.substring(_consumed.length);
    // Close a dangling fence so speech preparation drops the code.
    if (_fenceOpen(content, content.length)) rest = '$rest\n```';
    _consumed = content;
    _last = content;
    if (rest.trim().isNotEmpty) sentences.add(rest);
    return sentences;
  }

  void reset() {
    _consumed = '';
    _last = '';
  }

  bool _endsSentence(String text, int i, int pieceLength) {
    final char = text[i];
    if (_terminators.contains(char)) return true;
    if (char == '.') {
      // "Done. Next" ends a sentence; "3.14", "1. item" and "e.g." do not.
      final next = i + 1 < text.length ? text[i + 1] : '';
      final prev = i > 0 ? text[i - 1] : '';
      return (next == ' ' || next == '\n') &&
          RegExp(r'[A-Za-z)]').hasMatch(prev);
    }
    return pieceLength >= softBreakAfter && _softBreaks.contains(char);
  }

  static bool _fenceOpen(String text, int end) {
    var open = false;
    var i = text.indexOf('```');
    while (i >= 0 && i < end) {
      open = !open;
      i = text.indexOf('```', i + 3);
    }
    return open;
  }
}
