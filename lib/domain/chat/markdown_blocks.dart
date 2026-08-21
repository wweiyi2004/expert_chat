/// Splits Markdown into stable block strings for streaming UI.
///
/// Completed blocks keep the same string as more text is appended, so a
/// renderer can freeze them and only re-parse the last open block.
///
/// Math (`$$`, `\[ \]`, `\begin{...}`) is never split: GptMarkdown converts
/// `$` delimiters per widget, so a cut formula renders as raw TeX / italics.
List<String> splitMarkdownBlocks(String markdown) {
  if (markdown.isEmpty) return const [];

  final normalized = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  final blocks = <String>[];
  final buf = StringBuffer();
  var inFence = false;
  var fenceMarker = '';

  void flush() {
    final text = buf.toString();
    buf.clear();
    if (text.trim().isEmpty) return;
    blocks.add(text.trimRight());
  }

  bool mathOpen() => _hasUnclosedMath(buf.toString());

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final isLast = i == lines.length - 1;
    final newline = isLast ? '' : '\n';

    if (inFence) {
      buf.write(line);
      buf.write(newline);
      if (_closesFence(line, fenceMarker)) {
        inFence = false;
        fenceMarker = '';
        flush();
      }
      continue;
    }

    final fence = _openingFence(line);
    if (fence != null && !mathOpen()) {
      flush();
      inFence = true;
      fenceMarker = fence;
      buf.write(line);
      buf.write(newline);
      continue;
    }

    if ((_isAtxHeading(line) || _isThematicBreak(line)) && !mathOpen()) {
      flush();
      buf.write(line);
      buf.write(newline);
      flush();
      continue;
    }

    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      if (mathOpen()) {
        buf.write(line);
        buf.write(newline);
        continue;
      }
      final next = _nextNonEmpty(lines, i + 1);
      if (next != null &&
          _isListItem(next) &&
          _startsWithListItem(buf.toString())) {
        buf.write(line);
        buf.write(newline);
        continue;
      }
      flush();
      continue;
    }

    buf.write(line);
    buf.write(newline);
  }

  flush();
  return blocks;
}

final _fenceLine = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})(.*)$');
final _atxHeading = RegExp(r'^[ \t]{0,3}#{1,6}(?:\s|$)');
final _thematicBreak = RegExp(r'^[ \t]{0,3}(?:(-{3,})|(\*{3,})|(_{3,}))[ \t]*$');
final _listItem = RegExp(r'^[ \t]{0,3}(?:[-*+]|\d+[.)])\s+');

String? _openingFence(String line) {
  final match = _fenceLine.firstMatch(line);
  if (match == null) return null;
  final marker = match.group(1)!;
  final info = match.group(2) ?? '';
  if (marker.startsWith('`') && info.contains('`')) return null;
  return marker;
}

bool _closesFence(String line, String openMarker) {
  final match = _fenceLine.firstMatch(line);
  if (match == null) return false;
  final marker = match.group(1)!;
  if (marker[0] != openMarker[0]) return false;
  if (marker.length < openMarker.length) return false;
  return match.group(2)!.trim().isEmpty;
}

bool _isAtxHeading(String line) => _atxHeading.hasMatch(line);

bool _isThematicBreak(String line) => _thematicBreak.hasMatch(line);

bool _isListItem(String line) => _listItem.hasMatch(line);

bool _startsWithListItem(String block) {
  for (final line in block.split('\n')) {
    if (line.trim().isEmpty) continue;
    return _isListItem(line);
  }
  return false;
}

String? _nextNonEmpty(List<String> lines, int start) {
  for (var i = start; i < lines.length; i++) {
    if (lines[i].trim().isNotEmpty) return lines[i];
  }
  return null;
}

final _beginEnv = RegExp(r'^\\begin\{([a-zA-Z*]+)\}');
final _endEnv = RegExp(r'^\\end\{([a-zA-Z*]+)\}');

/// True when [text] still has an open `$$`, `\[`, `\(` or `\begin{...}`.
/// Single `$` is ignored so currency like `$5` does not swallow the rest.
bool _hasUnclosedMath(String text) {
  if (text.isEmpty) return false;
  var displayDollars = false;
  var brackets = 0;
  var parens = 0;
  final envs = <String>[];

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == r'\' && i + 1 < text.length) {
      final next = text[i + 1];
      if (next == '[') {
        brackets++;
        i++;
        continue;
      }
      if (next == ']') {
        if (brackets > 0) brackets--;
        i++;
        continue;
      }
      if (next == '(') {
        parens++;
        i++;
        continue;
      }
      if (next == ')') {
        if (parens > 0) parens--;
        i++;
        continue;
      }
      final slice = text.substring(i);
      final begin = _beginEnv.firstMatch(slice);
      if (begin != null) {
        envs.add(begin.group(1)!);
        i += begin.end - 1;
        continue;
      }
      final end = _endEnv.firstMatch(slice);
      if (end != null) {
        final name = end.group(1)!;
        final idx = envs.lastIndexOf(name);
        if (idx >= 0) envs.removeAt(idx);
        i += end.end - 1;
        continue;
      }
      i++;
      continue;
    }
    if (c == r'$') {
      if (i + 1 < text.length && text[i + 1] == r'$') {
        displayDollars = !displayDollars;
        i++;
      }
    }
  }

  return displayDollars || brackets > 0 || parens > 0 || envs.isNotEmpty;
}
