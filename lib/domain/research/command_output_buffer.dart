import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import '../desktop/command_runner_contract.dart';

/// Retain bounded beginning/end excerpts without copying the accumulated log
/// on each SSH packet. The tail keeps final errors and command summaries.
class CommandOutputBuffer {
  CommandOutputBuffer({this.maxChars = 16000}) : assert(maxChars >= 8);
  final int maxChars;
  final _head = StringBuffer();
  final _tail = ListQueue<String>();
  int _tailLength = 0;
  bool _headClosed = false;
  int totalChars = 0;
  int get retainedChars => _head.length + _tailLength;
  bool get truncated => totalChars > retainedChars;

  static int _boundary(String text, int offset) {
    if (offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset - 1) >= 0xd800 &&
        text.codeUnitAt(offset - 1) <= 0xdbff &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff) {
      return offset - 1;
    }
    return offset;
  }

  void add(String text) {
    if (text.isEmpty) return;
    totalChars += text.length;
    final headRoom = maxChars ~/ 3 - _head.length;
    if (!_headClosed && headRoom > 0) {
      final end = _boundary(text, headRoom.clamp(0, text.length));
      _head.write(text.substring(0, end));
      text = text.substring(end);
      _headClosed = text.isNotEmpty || _head.length >= maxChars ~/ 3;
    }
    if (text.isEmpty) return;
    final limit = maxChars - _head.length;
    if (text.length > limit) {
      var start = _boundary(text, text.length - limit);
      if (text.length - start > limit) start += 2;
      text = text.substring(start);
      _tail.clear();
      _tailLength = 0;
    }
    _tail.add(text);
    _tailLength += text.length;
    while (_tailLength > limit && _tail.isNotEmpty) {
      final first = _tail.removeFirst();
      final excess = _tailLength - limit;
      if (first.length <= excess) {
        _tailLength -= first.length;
      } else {
        var start = _boundary(first, excess);
        if (start < excess) start += 2;
        _tail.addFirst(first.substring(start));
        _tailLength -= start;
      }
    }
  }

  String get text =>
      '${_head.toString()}${truncated ? '\n【输出过长，已省略中间 ${totalChars - retainedChars} 个字符；保留开头和末尾，请按范围读取所需内容】\n' : ''}${_tail.join()}';
}

/// Decode incrementally and yield to timers, cancellation and UI transport
/// during a high-volume stream rather than draining every packet in one turn.
Stream<String> decodeCommandOutput(Stream<List<int>> bytes) async* {
  var work = 0;
  await for (final text in bytes.transform(
    const Utf8Decoder(allowMalformed: true),
  )) {
    yield text;
    work += text.length;
    if (work >= 256 * 1024) {
      work = 0;
      await Future<void>.delayed(Duration.zero);
    }
  }
}

/// At most two bounded UI notifications per frame interval, even for commands
/// producing thousands of tiny stdout/stderr packets. Always flush at exit.
class CommandOutputBatch {
  CommandOutputBatch(this.onOutput);
  final WorkspaceCommandOutput? onOutput;
  CommandOutputBuffer? _out, _err;
  Timer? _timer;
  void add(String text, bool stderr) {
    if (onOutput == null || text.isEmpty) return;
    final buffer = stderr
        ? (_err ??= CommandOutputBuffer(maxChars: 32000))
        : (_out ??= CommandOutputBuffer(maxChars: 32000));
    buffer.add(text);
    _timer ??= Timer(const Duration(milliseconds: 80), flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final out = _out, err = _err;
    _out = null;
    _err = null;
    if (out != null) onOutput?.call(out.text, false);
    if (err != null) onOutput?.call(err.text, true);
  }
}
