/// Bounded raw terminal chunks with a monotonic cursor. Rendering clients own
/// their xterm screen; they never own the remote SSH transport.
class HostTerminalOutput {
  final _chunks = <({int cursor, String text})>[];
  int _cursor = 0, _length = 0, _generation = 0;
  static const limit = 2 * 1024 * 1024;
  void reset() {
    _chunks.clear();
    _length = 0;
    _generation++;
  }

  void add(String text) {
    if (text.isEmpty) return;
    for (var start = 0; start < text.length;) {
      var end = (start + 16384).clamp(0, text.length);
      if (end < text.length &&
          text.codeUnitAt(end - 1) >= 0xd800 &&
          text.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
      final chunk = text.substring(start, end);
      _chunks.add((cursor: ++_cursor, text: chunk));
      _length += chunk.length;
      start = end;
    }
    while (_length > limit && _chunks.length > 1) {
      _length -= _chunks.removeAt(0).text.length;
    }
  }

  Map<String, Object?> read(int cursor, int generation) {
    final reset =
        generation != _generation ||
        cursor > _cursor ||
        _chunks.isNotEmpty && cursor < _chunks.first.cursor - 1;
    final chunks = _chunks
        .where((c) => reset || c.cursor > cursor)
        .take(32)
        .toList();
    return {
      'reset': reset,
      'generation': _generation,
      'cursor': chunks.lastOrNull?.cursor ?? _cursor,
      'has_more': chunks.isNotEmpty && chunks.last.cursor < _cursor,
      'text': chunks.map((c) => c.text).join(),
      'truncated': reset && _chunks.isNotEmpty && _chunks.first.cursor > 1,
    };
  }
}
