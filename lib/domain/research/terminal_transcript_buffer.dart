import 'dart:convert';

/// Bounded plain-text buffer of terminal output for optional AI context.
class TerminalTranscriptBuffer {
  TerminalTranscriptBuffer({this.maxLines = 2000, this.maxBytes = 512 * 1024});

  final int maxLines;
  final int maxBytes;

  final List<String> _lines = [];
  int _byteCount = 0;
  String _pendingLine = '';

  int get lineCount => _lines.length + (_pendingLine.isEmpty ? 0 : 1);
  int get byteCount => _byteCount + utf8.encode(_pendingLine).length;

  void clear() {
    _lines.clear();
    _byteCount = 0;
    _pendingLine = '';
  }

  void append(String chunk) {
    if (chunk.isEmpty) return;
    final raw = '$_pendingLine$chunk';
    final completed = <String>[];
    var start = 0;
    var i = 0;
    while (i < raw.length) {
      final code = raw.codeUnitAt(i);
      if (code == 0x0a) {
        completed.add(raw.substring(start, i));
        start = i + 1;
      } else if (code == 0x0d) {
        // Keep a trailing CR pending until the next chunk so a split CRLF is
        // treated as one logical newline.
        if (i == raw.length - 1) break;
        if (raw.codeUnitAt(i + 1) == 0x0a) {
          // CRLF is one logical newline.
          completed.add(raw.substring(start, i));
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
    _pendingLine = raw.substring(start);
    for (final line in completed) {
      _pushLine(stripAnsiAndControls(line));
    }
    _trim();
  }

  void _pushLine(String line) {
    final bytes = utf8.encode(line).length;
    _lines.add(line);
    _byteCount += bytes + 1;
    _trim();
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
    // CSI / OSC-ish ANSI sequences
    var s = input.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');
    s = s.replaceAll(RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?'), '');
    s = s.replaceAll(RegExp(r'\x1B[@-Z\\-_]'), '');
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
