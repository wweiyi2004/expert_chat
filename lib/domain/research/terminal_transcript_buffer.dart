import 'dart:convert';

/// Bounded plain-text buffer of terminal output for optional AI context.
class TerminalTranscriptBuffer {
  TerminalTranscriptBuffer({this.maxLines = 2000, this.maxBytes = 512 * 1024});

  final int maxLines;
  final int maxBytes;

  final List<String> _lines = [];
  int _byteCount = 0;

  int get lineCount => _lines.length;
  int get byteCount => _byteCount;

  void clear() {
    _lines.clear();
    _byteCount = 0;
  }

  void append(String chunk) {
    if (chunk.isEmpty) return;
    final cleaned = stripAnsiAndControls(chunk);
    if (cleaned.isEmpty) return;
    for (final piece in cleaned.split('\n')) {
      // Keep empty lines as blank so line counts match user expectation.
      _pushLine(piece);
    }
  }

  void _pushLine(String line) {
    // Drop CR leftovers from CRLF.
    var s = line.replaceAll('\r', '');
    final bytes = utf8.encode(s).length;
    _lines.add(s);
    _byteCount += bytes + 1;
    _trim();
  }

  void _trim() {
    while (_lines.length > maxLines ||
        (_byteCount > maxBytes && _lines.isNotEmpty)) {
      final removed = _lines.removeAt(0);
      _byteCount -= utf8.encode(removed).length + 1;
      if (_byteCount < 0) _byteCount = 0;
    }
  }

  /// Last [n] lines, joined, with secrets redacted.
  String recentForAi(int n) {
    if (n <= 0 || _lines.isEmpty) return '';
    final start = (_lines.length - n).clamp(0, _lines.length);
    final slice = _lines.sublist(start);
    return redactSecrets(slice.join('\n'));
  }

  /// Public for tests.
  static String stripAnsiAndControls(String input) {
    // CSI / OSC-ish ANSI sequences
    var s = input.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');
    s = s.replaceAll(RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?'), '');
    s = s.replaceAll(RegExp(r'\x1B[@-Z\\-_]'), '');
    // Other C0 controls except \n \t
    s = s.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '');
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
