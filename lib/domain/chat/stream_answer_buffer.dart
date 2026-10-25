/// Accumulates one answer across model/tool rounds without publishing UI state.
class StreamAnswerBuffer {
  StreamAnswerBuffer({Stopwatch? thinkingClock})
    : _thinkingClock = thinkingClock ?? Stopwatch();

  final _content = StringBuffer();
  final _reasoning = StringBuffer();
  final Stopwatch _thinkingClock;
  int _thinkingMillis = 0;
  bool _contentRoundBoundary = false;

  String get content => _content.toString();
  String get reasoning => _reasoning.toString();
  int get totalLength => _content.length + _reasoning.length;
  int get thinkingMillis => _thinkingMillis;
  bool get isThinking => _thinkingClock.isRunning;

  void addReasoning(String text) {
    if (text.isEmpty) return;
    if (!_thinkingClock.isRunning) _thinkingClock.start();
    _reasoning.write(text);
  }

  void addContent(String text) {
    if (text.isEmpty) return;
    stopThinking();
    if (_contentRoundBoundary && _content.isNotEmpty) _content.write("\n\n");
    _contentRoundBoundary = false;
    _content.write(text);
  }

  /// Keep published model prose when tools run; separate the next response.
  void finishToolRound() {
    _contentRoundBoundary = _content.isNotEmpty;
  }

  /// Local status notes do not start the model's thinking clock.
  void appendReasoningNote(String text) => _reasoning.write(text);

  void replaceContent(String text) => _content
    ..clear()
    ..write(text);

  void replaceReasoning(String text) => _reasoning
    ..clear()
    ..write(text);

  /// Keep elapsed time across tool rounds; only a new answer resets the clock.
  void stopThinking({bool recordElapsed = true}) {
    if (!_thinkingClock.isRunning) return;
    _thinkingClock.stop();
    if (recordElapsed) _thinkingMillis = _thinkingClock.elapsedMilliseconds;
  }
}
