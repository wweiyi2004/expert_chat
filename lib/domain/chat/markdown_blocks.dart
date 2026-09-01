/// Coarse Markdown block kinds used by the streaming renderer.
enum StreamingMarkdownBlockType {
  paragraph,
  heading,
  thematicBreak,
  fencedCode,
  list,
  blockQuote,
  table,
  math,
  html,
}

/// State retained for the one block that may still change as text arrives.
class MarkdownParserContext {
  const MarkdownParserContext({
    this.blockType,
    this.openFenceMarker,
    this.hasUnclosedMath = false,
    this.awaitingListContinuation = false,
    this.hasUnclosedInlineCode = false,
    this.hasUnclosedStrong = false,
    this.hasUnclosedLink = false,
  });

  final StreamingMarkdownBlockType? blockType;
  final String? openFenceMarker;
  final bool hasUnclosedMath;
  final bool awaitingListContinuation;
  final bool hasUnclosedInlineCode;
  final bool hasUnclosedStrong;
  final bool hasUnclosedLink;

  bool get hasPendingSyntax =>
      openFenceMarker != null ||
      hasUnclosedMath ||
      awaitingListContinuation ||
      hasUnclosedInlineCode ||
      hasUnclosedStrong ||
      hasUnclosedLink;
}

/// A renderable block with an identity that survives append-only updates.
class StreamingMarkdownBlock {
  const StreamingMarkdownBlock({
    required this.id,
    required this.type,
    required this.source,
    required this.isStable,
    required this.revision,
  });

  final int id;
  final StreamingMarkdownBlockType type;
  final String source;

  /// Stable blocks can no longer be changed by text appended to the document.
  final bool isStable;

  /// Increases while the same pending block receives more source text.
  final int revision;
}

enum MarkdownSnapshotUpdate { unchanged, appended, reset, finalized }

/// Incremental Markdown document for append-only LLM output.
///
/// The chat state publishes complete snapshots, not raw deltas. This class
/// detects the appended suffix and only scans that suffix plus the unfinished
/// tail. Blocks before the tail are immutable and never enter the parser again.
/// A non-append edit (branch switch, regeneration, message edit, tool reset)
/// safely falls back to a full reset.
class StreamingMarkdownDocument {
  final List<StreamingMarkdownBlock> _stableBlocks = [];
  StreamingMarkdownBlock? _pendingBlock;
  String _pendingRaw = '';
  String _content = '';
  int _rawSnapshotLength = 0;
  bool _rawEndsWithCarriageReturn = false;
  bool _rawSnapshotIsNormalized = true;
  bool _isFinal = false;
  int _nextBlockId = 0;

  /// Instrumentation used by regression tests and performance diagnostics.
  int lastParsedCharacters = 0;
  int totalParsedCharacters = 0;
  int resetCount = 0;

  String get content => _content;
  bool get isFinal => _isFinal;
  List<StreamingMarkdownBlock> get stableBlocks =>
      List.unmodifiable(_stableBlocks);
  StreamingMarkdownBlock? get pendingBlock => _pendingBlock;
  MarkdownParserContext get context =>
      _tailContext ?? const MarkdownParserContext();

  List<StreamingMarkdownBlock> get blocks =>
      List.unmodifiable([..._stableBlocks, ?_pendingBlock]);

  MarkdownParserContext? _tailContext;

  /// Applies a complete UI snapshot, incrementally when it extends the old one.
  ///
  /// Set [assumeAppendOnly] only when the caller owns an active append-only
  /// stream. It skips a full prefix comparison; length shrinkage and finalized
  /// documents still reset normally.
  MarkdownSnapshotUpdate updateSnapshot(
    String snapshot, {
    required bool isFinal,
    bool assumeAppendOnly = false,
  }) {
    if (assumeAppendOnly &&
        !_isFinal &&
        snapshot.length >= _rawSnapshotLength) {
      final rawDelta = snapshot.substring(_rawSnapshotLength);
      if (rawDelta.isEmpty) {
        _rawSnapshotLength = snapshot.length;
        _rawEndsWithCarriageReturn = snapshot.endsWith('\r');
        if (isFinal == _isFinal) return MarkdownSnapshotUpdate.unchanged;
        _parsePending('', isFinal: true);
        _isFinal = true;
        return MarkdownSnapshotUpdate.finalized;
      }
      final delta = _normalizeMarkdownDelta(
        rawDelta,
        dropLeadingLineFeed: _rawEndsWithCarriageReturn,
      );
      if (_rawSnapshotIsNormalized && delta == rawDelta) {
        // The stream uses LF already, so retain the controller's complete
        // snapshot by reference instead of copying the growing prefix.
        _content = snapshot;
      } else {
        _content = '$_content$delta';
      }
      _rawSnapshotLength = snapshot.length;
      _rawEndsWithCarriageReturn = snapshot.endsWith('\r');
      _rawSnapshotIsNormalized = _rawSnapshotIsNormalized && delta == rawDelta;
      _parsePending(delta, isFinal: isFinal);
      _isFinal = isFinal;
      return MarkdownSnapshotUpdate.appended;
    }

    final normalized = _normalizeMarkdown(snapshot);
    if (normalized == _content) {
      _rawSnapshotLength = snapshot.length;
      _rawEndsWithCarriageReturn = snapshot.endsWith('\r');
      _rawSnapshotIsNormalized = snapshot == normalized;
      if (isFinal == _isFinal) return MarkdownSnapshotUpdate.unchanged;
      if (isFinal) {
        _parsePending('', isFinal: true);
        _isFinal = true;
        return MarkdownSnapshotUpdate.finalized;
      }
      _resetTo(
        normalized,
        rawSnapshotLength: snapshot.length,
        rawEndsWithCarriageReturn: snapshot.endsWith('\r'),
        rawSnapshotIsNormalized: snapshot == normalized,
        isFinal: false,
      );
      return MarkdownSnapshotUpdate.reset;
    }

    if (!_isFinal &&
        normalized.length >= _content.length &&
        (assumeAppendOnly || normalized.startsWith(_content))) {
      final delta = normalized.substring(_content.length);
      _content = normalized;
      _rawSnapshotLength = snapshot.length;
      _rawEndsWithCarriageReturn = snapshot.endsWith('\r');
      _rawSnapshotIsNormalized = snapshot == normalized;
      _parsePending(delta, isFinal: isFinal);
      _isFinal = isFinal;
      return MarkdownSnapshotUpdate.appended;
    }

    _resetTo(
      normalized,
      rawSnapshotLength: snapshot.length,
      rawEndsWithCarriageReturn: snapshot.endsWith('\r'),
      rawSnapshotIsNormalized: snapshot == normalized,
      isFinal: isFinal,
    );
    return MarkdownSnapshotUpdate.reset;
  }

  void _resetTo(
    String normalized, {
    required int rawSnapshotLength,
    required bool rawEndsWithCarriageReturn,
    required bool rawSnapshotIsNormalized,
    required bool isFinal,
  }) {
    _stableBlocks.clear();
    _pendingBlock = null;
    _pendingRaw = '';
    _tailContext = null;
    _content = normalized;
    _rawSnapshotLength = rawSnapshotLength;
    _rawEndsWithCarriageReturn = rawEndsWithCarriageReturn;
    _rawSnapshotIsNormalized = rawSnapshotIsNormalized;
    _isFinal = false;
    _nextBlockId = 0;
    resetCount++;
    _parsePending(normalized, isFinal: isFinal);
    _isFinal = isFinal;
  }

  void _parsePending(String delta, {required bool isFinal}) {
    final oldPending = _pendingBlock;
    final tail = '$_pendingRaw$delta';
    lastParsedCharacters = tail.length;
    totalParsedCharacters += tail.length;

    final parsed = _parseMarkdownTail(tail, isFinal: isFinal);
    _pendingBlock = null;
    _pendingRaw = parsed.pendingRaw;
    _tailContext = parsed.context;

    var reusedPendingIdentity = false;
    int allocateId() {
      if (!reusedPendingIdentity && oldPending != null) {
        reusedPendingIdentity = true;
        return oldPending.id;
      }
      return _nextBlockId++;
    }

    int revisionFor(int id) =>
        oldPending?.id == id ? oldPending!.revision + 1 : 0;

    for (final block in parsed.stable) {
      final id = allocateId();
      _stableBlocks.add(
        StreamingMarkdownBlock(
          id: id,
          type: block.type,
          source: block.source,
          isStable: true,
          revision: revisionFor(id),
        ),
      );
    }

    final pending = parsed.pending;
    if (pending != null) {
      final id = allocateId();
      _pendingBlock = StreamingMarkdownBlock(
        id: id,
        type: pending.type,
        source: pending.source,
        isStable: false,
        revision: revisionFor(id),
      );
    }
  }
}

/// Compatibility helper for complete documents and existing callers.
///
/// Streaming UI should keep one [StreamingMarkdownDocument] alive instead of
/// calling this function for every snapshot.
List<String> splitMarkdownBlocks(String markdown) {
  if (markdown.isEmpty) return const [];
  final document = StreamingMarkdownDocument()
    ..updateSnapshot(markdown, isFinal: true);
  return [for (final block in document.blocks) block.source];
}

class _ParsedMarkdownBlock {
  const _ParsedMarkdownBlock(this.source, this.type);

  final String source;
  final StreamingMarkdownBlockType type;
}

class _TailParseResult {
  const _TailParseResult({
    required this.stable,
    required this.pending,
    required this.pendingRaw,
    required this.context,
  });

  final List<_ParsedMarkdownBlock> stable;
  final _ParsedMarkdownBlock? pending;
  final String pendingRaw;
  final MarkdownParserContext context;
}

_TailParseResult _parseMarkdownTail(String markdown, {required bool isFinal}) {
  final stable = <_ParsedMarkdownBlock>[];
  final buffer = StringBuffer();
  final math = _MathState();
  var inFence = false;
  var fenceMarker = '';
  var blockStartsWithList = false;
  var awaitingListContinuation = false;

  void resetBlockState() {
    buffer.clear();
    math.reset();
    inFence = false;
    fenceMarker = '';
    blockStartsWithList = false;
    awaitingListContinuation = false;
  }

  void emitStable() {
    final source = buffer.toString().trimRight();
    if (source.trim().isNotEmpty) {
      stable.add(_ParsedMarkdownBlock(source, _blockTypeOf(source)));
    }
    resetBlockState();
  }

  void appendLine(
    String line, {
    required bool terminated,
    required bool trackMath,
  }) {
    if (buffer.length == 0 && line.trim().isNotEmpty) {
      blockStartsWithList = _isListItem(line);
    }
    buffer.write(line);
    if (terminated) buffer.write('\n');
    if (trackMath) {
      math.add(line);
      if (terminated) math.add('\n');
    }
  }

  var offset = 0;
  lineLoop:
  while (offset < markdown.length) {
    final newlineAt = markdown.indexOf('\n', offset);
    final terminated = newlineAt >= 0;
    final end = terminated ? newlineAt : markdown.length;
    final line = markdown.substring(offset, end);
    offset = terminated ? end + 1 : end;
    final isLastLine = offset >= markdown.length;

    while (true) {
      final trimmed = line.trim();

      if (inFence) {
        appendLine(line, terminated: terminated, trackMath: false);
        if (_closesFence(line, fenceMarker) &&
            (terminated || (isFinal && isLastLine))) {
          inFence = false;
          fenceMarker = '';
          emitStable();
        }
        continue lineLoop;
      }

      if (awaitingListContinuation && trimmed.isNotEmpty && !math.isOpen) {
        if (_isListItem(line)) {
          awaitingListContinuation = false;
          appendLine(line, terminated: terminated, trackMath: true);
          continue lineLoop;
        }
        if (!terminated && !isFinal && _couldBecomeListItem(line)) {
          appendLine(line, terminated: false, trackMath: true);
          continue lineLoop;
        }
        emitStable();
        // Re-evaluate this line as the start of the following block.
        continue;
      }

      if (math.isOpen) {
        appendLine(line, terminated: terminated, trackMath: true);
        continue lineLoop;
      }

      final fence = _openingFence(line);
      if (fence != null) {
        // Until the opening line is terminated it can still become invalid
        // (for example by receiving a backtick in a backtick-fence info word).
        // Keep the preceding content in the mutable tail in that case.
        if (terminated || (isFinal && isLastLine)) {
          emitStable();
        }
        inFence = true;
        fenceMarker = fence;
        appendLine(line, terminated: terminated, trackMath: false);
        continue lineLoop;
      }

      if ((_isAtxHeading(line) || _isThematicBreak(line)) &&
          (terminated || (isFinal && isLastLine))) {
        emitStable();
        appendLine(line, terminated: terminated, trackMath: false);
        emitStable();
        continue lineLoop;
      }

      if (trimmed.isEmpty) {
        if (buffer.length == 0) continue lineLoop;
        if (blockStartsWithList) {
          appendLine(line, terminated: terminated, trackMath: true);
          awaitingListContinuation = true;
        } else {
          emitStable();
        }
        continue lineLoop;
      }

      appendLine(line, terminated: terminated, trackMath: true);
      continue lineLoop;
    }
  }

  if (isFinal) emitStable();

  final pendingRaw = isFinal ? '' : buffer.toString();
  final pendingSource = pendingRaw.trimRight();
  final pending = pendingSource.trim().isEmpty
      ? null
      : _ParsedMarkdownBlock(pendingSource, _blockTypeOf(pendingSource));
  final inline = _scanInlineState(pendingSource);
  final context = pending == null
      ? const MarkdownParserContext()
      : MarkdownParserContext(
          blockType: pending.type,
          openFenceMarker: inFence ? fenceMarker : null,
          hasUnclosedMath: math.isOpen,
          awaitingListContinuation: awaitingListContinuation,
          hasUnclosedInlineCode: inline.hasUnclosedCode,
          hasUnclosedStrong: inline.hasUnclosedStrong,
          hasUnclosedLink: inline.hasUnclosedLink,
        );

  return _TailParseResult(
    stable: stable,
    pending: pending,
    pendingRaw: pendingRaw,
    context: context,
  );
}

final _fenceLine = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})(.*)$');
final _atxHeading = RegExp(r'^[ \t]{0,3}#{1,6}(?:\s|$)');
final _thematicBreak = RegExp(
  r'^[ \t]{0,3}(?:(-{3,})|(\*{3,})|(_{3,}))[ \t]*$',
);
final _listItem = RegExp(r'^[ \t]{0,3}(?:[-*+]|\d+[.)])\s+');
final _blockQuote = RegExp(r'^[ \t]{0,3}>');
final _tableDelimiter = RegExp(
  r'^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$',
);
final _htmlBlock = RegExp(r'^\s*</?[a-zA-Z][^>]*>|^\s*<!--');

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

bool _couldBecomeListItem(String line) {
  final candidate = line.trimLeft();
  if (line.length - candidate.length > 3) return false;
  if (candidate == '-' || candidate == '*' || candidate == '+') return true;
  return RegExp(r'^\d+(?:[.)])?$').hasMatch(candidate);
}

StreamingMarkdownBlockType _blockTypeOf(String source) {
  final lines = source.split('\n');
  final first = lines.firstWhere(
    (line) => line.trim().isNotEmpty,
    orElse: () => '',
  );
  final trimmed = first.trimLeft();
  if (_openingFence(first) != null) {
    return StreamingMarkdownBlockType.fencedCode;
  }
  if (_isAtxHeading(first)) return StreamingMarkdownBlockType.heading;
  if (_isThematicBreak(first)) {
    return StreamingMarkdownBlockType.thematicBreak;
  }
  if (_isListItem(first)) return StreamingMarkdownBlockType.list;
  if (_blockQuote.hasMatch(first)) {
    return StreamingMarkdownBlockType.blockQuote;
  }
  if (trimmed.startsWith(r'$$') ||
      trimmed.startsWith(r'\[') ||
      trimmed.startsWith(r'\begin{')) {
    return StreamingMarkdownBlockType.math;
  }
  if (lines.length >= 2 && _tableDelimiter.hasMatch(lines[1])) {
    return StreamingMarkdownBlockType.table;
  }
  if (_htmlBlock.hasMatch(first)) return StreamingMarkdownBlockType.html;
  return StreamingMarkdownBlockType.paragraph;
}

String _normalizeMarkdown(String markdown) =>
    markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String _normalizeMarkdownDelta(
  String delta, {
  required bool dropLeadingLineFeed,
}) {
  final adjusted = dropLeadingLineFeed && delta.startsWith('\n')
      ? delta.substring(1)
      : delta;
  return adjusted.contains('\r') ? _normalizeMarkdown(adjusted) : adjusted;
}

final _beginEnv = RegExp(r'^\\begin\{([a-zA-Z*]+)\}');
final _endEnv = RegExp(r'^\\end\{([a-zA-Z*]+)\}');

class _MathState {
  bool displayDollars = false;
  int brackets = 0;
  int parens = 0;
  final List<String> environments = [];

  bool get isOpen =>
      displayDollars || brackets > 0 || parens > 0 || environments.isNotEmpty;

  void reset() {
    displayDollars = false;
    brackets = 0;
    parens = 0;
    environments.clear();
  }

  void add(String text) {
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == r'\' && i + 1 < text.length) {
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
          environments.add(begin.group(1)!);
          i += begin.end - 1;
          continue;
        }
        final end = _endEnv.firstMatch(slice);
        if (end != null) {
          final name = end.group(1)!;
          final index = environments.lastIndexOf(name);
          if (index >= 0) environments.removeAt(index);
          i += end.end - 1;
          continue;
        }
        i++;
        continue;
      }
      if (char == r'$' && i + 1 < text.length && text[i + 1] == r'$') {
        displayDollars = !displayDollars;
        i++;
      }
    }
  }
}

class _InlineState {
  const _InlineState({
    required this.hasUnclosedCode,
    required this.hasUnclosedStrong,
    required this.hasUnclosedLink,
  });

  final bool hasUnclosedCode;
  final bool hasUnclosedStrong;
  final bool hasUnclosedLink;
}

_InlineState _scanInlineState(String text) {
  var codeTicks = 0;
  final strongMarkers = <String>[];
  var brackets = 0;
  var linkParens = 0;

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == r'\') {
      i++;
      continue;
    }
    if (char == '`') {
      var run = 1;
      while (i + run < text.length && text[i + run] == '`') {
        run++;
      }
      if (codeTicks == 0) {
        codeTicks = run;
      } else if (codeTicks == run) {
        codeTicks = 0;
      }
      i += run - 1;
      continue;
    }
    if (codeTicks != 0) continue;

    if (i + 1 < text.length) {
      final pair = text.substring(i, i + 2);
      if (pair == '**' || pair == '__') {
        if (strongMarkers.isNotEmpty && strongMarkers.last == pair) {
          strongMarkers.removeLast();
        } else {
          strongMarkers.add(pair);
        }
        i++;
        continue;
      }
    }

    if (char == '[') {
      brackets++;
    } else if (char == ']' &&
        i + 1 < text.length &&
        text[i + 1] == '(' &&
        brackets > 0) {
      brackets--;
      linkParens++;
      i++;
    } else if (char == '(' && linkParens > 0) {
      linkParens++;
    } else if (char == ')' && linkParens > 0) {
      linkParens--;
    }
  }

  return _InlineState(
    hasUnclosedCode: codeTicks != 0,
    hasUnclosedStrong: strongMarkers.isNotEmpty,
    hasUnclosedLink: brackets > 0 || linkParens > 0,
  );
}
