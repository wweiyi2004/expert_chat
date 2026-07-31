import 'dart:convert';

/// Bounded plain-text buffer of terminal output for optional AI context.
class TerminalTranscriptBuffer {
  TerminalTranscriptBuffer({this.maxLines = 2000, this.maxBytes = 512 * 1024});

  final int maxLines;
  final int maxBytes;

  final List<String> _lines = [];
  int _byteCount = 0;
  String _pendingLine = '';

  /// An un-terminated ANSI escape at the tail of the last chunk, held until
  /// the next chunk arrives. SSH splits byte streams at arbitrary points, so
  /// `\x1B[3` + `1m` arrives as two chunks; stripping per chunk would leave
  /// the half-built sequence to leak into the AI context.
  String _ansiPartial = '';

  int get lineCount => _lines.length + (_pendingLine.isEmpty ? 0 : 1);
  int get byteCount => _byteCount + utf8.encode(_pendingLine).length;

  void clear() {
    _lines.clear();
    _byteCount = 0;
    _pendingLine = '';
    _ansiPartial = '';
  }

  void append(String chunk) {
    if (chunk.isEmpty && _ansiPartial.isEmpty) return;
    // The pending line carries the previous chunk's tail (a split CRLF, a
    // half-escape), and _ansiPartial the escape itself — both must rejoin
    // before any per-line processing.
    final raw = '$_pendingLine$_ansiPartial$chunk';
    _ansiPartial = '';
    // Rejoin any escape the previous chunk left open before processing lines.
    final partial = _partialEscapeRange(raw);
    final head = partial.start == raw.length
        ? raw
        : raw.substring(0, partial.start);
    if (partial.start < raw.length) {
      // Hold the escape tail; a newline it straddles ([partial.end, raw.end))
      // is display noise and is dropped with it.
      _ansiPartial = raw.substring(partial.start, partial.end);
    }
    final completed = <String>[];
    var start = 0;
    var i = 0;
    while (i < head.length) {
      final code = head.codeUnitAt(i);
      if (code == 0x0a) {
        completed.add(head.substring(start, i));
        start = i + 1;
      } else if (code == 0x0d) {
        // Keep a trailing CR pending until the next chunk so a split CRLF is
        // treated as one logical newline.
        if (i == head.length - 1) break;
        if (head.codeUnitAt(i + 1) == 0x0a) {
          // CRLF is one logical newline.
          completed.add(head.substring(start, i));
          i++;
          start = i + 1;
        } else {
          // A lone CR is a carriage return, not a newline: the remote redraws
          // the same line. Emitting a line per redraw would let one tqdm bar
          // flood the whole AI context, so drop what was drawn and restart the
          // line instead.
          start = i + 1;
        }
      }
      i++;
    }
    _pendingLine = head.substring(start);
    for (final line in completed) {
      _pushLine(stripAnsiAndControls(line));
    }
    _trim();
  }

  /// Longest suffix of [raw] that is an un-terminated ANSI escape prefix (no
  /// final byte yet) as a (start, end) index range; start == [raw.length] when
  /// there is none. A trailing newline is skipped so an escape interrupted
  /// right before the line break (e.g. `\x1B[3\n`) is still rejoined instead
  /// of leaking `[3` into context — the straddled newline is display noise and
  /// is dropped with the escape.
  static ({int start, int end}) _partialEscapeRange(String raw) {
    var end = raw.length;
    if (end > 0 && raw.codeUnitAt(end - 1) == 0x0a) {
      end--;
      if (end > 0 && raw.codeUnitAt(end - 1) == 0x0d) end--;
    }
    // Real escapes are short; cap the scan so a pathological run of params
    // does not make every append quadratic.
    const maxHold = 256;
    var start = raw.length;
    for (var len = 1; len <= end && len <= maxHold; len++) {
      if (_isPartialEscape(raw.substring(end - len, end))) {
        start = end - len;
      }
    }
    return (start: start, end: end);
  }

  static bool _isPartialEscape(String s) {
    // ESC alone, or ESC + intermediates (charset declarations etc.) with no
    // final byte yet.
    if (s == '\x1B' || RegExp(r'^\x1B[ -/]+$').hasMatch(s)) return true;
    // CSI without its final byte: ESC [ params(0-9;?) intermediates(space-/)*.
    if (RegExp(r'^\x1B\[[0-9;?]*[ -/]*$').hasMatch(s)) return true;
    // OSC / DCS / PM / APC opener without content or terminator.
    if (RegExp(r'^\x1B[\]PX^_]$').hasMatch(s)) return true;
    return false;
  }

  void _pushLine(String line) {
    // A remote program can emit a line longer than maxBytes (e.g. a minified
    // file dumped to the terminal). Truncate it to its newest tail, like the
    // pending-line logic below, instead of letting _trim evict it wholesale
    // and leave the AI context empty. maxBytes - 1 leaves room for the
    // newline accounting so _trim keeps the line.
    var text = line;
    var bytes = utf8.encode(text).length;
    if (bytes > maxBytes - 1) {
      text = _truncateTail(text, maxBytes - 1);
      bytes = utf8.encode(text).length;
    }
    _lines.add(text);
    _byteCount += bytes + 1;
    _trim();
  }

  /// Keep the newest [budget] bytes of [line], dropping the head.
  String _truncateTail(String line, int budget) {
    final encoded = utf8.encode(line);
    var toDrop = encoded.length - budget;
    var cut = 0;
    while (toDrop > 0 && cut < line.length) {
      final c = line.codeUnitAt(cut);
      toDrop -= c < 0x80 ? 1 : (c < 0x800 ? 2 : 3);
      cut++;
    }
    return line.substring(cut);
  }

  void _trim() {
    int totalBytes() => _byteCount + utf8.encode(_pendingLine).length;

    while ((_lines.length + (_pendingLine.isEmpty ? 0 : 1) > maxLines ||
            totalBytes() > maxBytes) &&
        _lines.isNotEmpty) {
      final removed = _lines.removeAt(0);
      _byteCount -= utf8.encode(removed).length + 1;
      if (_byteCount < 0) _byteCount = 0;
    }
    // A remote program can emit an arbitrarily long line. Keep the newest
    // portion bounded instead of allowing the pending line to grow forever.
    while (_pendingLine.isNotEmpty && totalBytes() > maxBytes) {
      final drop = (_pendingLine.length / 8).ceil().clamp(
        1,
        _pendingLine.length,
      );
      _pendingLine = _pendingLine.substring(drop);
    }
  }

  /// Last [n] lines, joined, with secrets redacted.
  String recentForAi(int n) {
    if (n <= 0 || (_lines.isEmpty && _pendingLine.isEmpty)) return '';
    final all = <String>[
      ..._lines,
      if (_pendingLine.isNotEmpty) stripAnsiAndControls(_pendingLine),
    ];
    final start = (all.length - n).clamp(0, all.length);
    final slice = all.sublist(start);
    return redactSecrets(slice.join('\n'));
  }

  /// Public for tests.
  static String stripAnsiAndControls(String input) {
    // CSI: ESC [ params(0-9;?) intermediates(space-/)* final(@-~).
    var s = input.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');
    // OSC (ESC ]) / DCS (ESC P) / PM (ESC ^) / APC (ESC _) run until ST.
    s = s.replaceAll(RegExp(r'\x1B[\]PX^_][^\x07\x1B]*(?:\x07|\x1B\\)?'), '');
    // Two-byte escapes with optional intermediate bytes — charset
    // declarations like ESC ( B / ESC % G, screen features like ESC # 8.
    s = s.replaceAll(RegExp(r'\x1B[ -/]*[0-?@-~]'), '');
    // Other C0 controls except \n \t. CR is included: append() has already
    // applied carriage-return semantics, so any left over is display noise.
    s = s.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f]'), '');
    return s;
  }

  static String redactSecrets(String input) {
    var s = input;
    // Bearer / API key style
    s = s.replaceAllMapped(
      RegExp(
        r'(api[_-]?key|token|secret|password|passwd|authorization)\s*[=:]\s*(\S+)',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}=***REDACTED***',
    );
    s = s.replaceAllMapped(
      RegExp(r'(bearer)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      (m) => '${m.group(1)} ***REDACTED***',
    );
    // sk- / common key prefixes
    s = s.replaceAll(
      RegExp(r'\b(sk|rk|pk)-[A-Za-z0-9]{8,}\b'),
      '***REDACTED_KEY***',
    );
    // PEM blocks
    s = s.replaceAll(
      RegExp(
        r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----',
      ),
      '-----BEGIN PRIVATE KEY-----\n***REDACTED***\n-----END PRIVATE KEY-----',
    );
    return s;
  }
}
