import 'dart:typed_data';
import 'dart:convert';

enum DiffLineKind { context, added, removed }

class DiffLine {
  const DiffLine(this.kind, this.text, this.oldLine, this.newLine);
  final DiffLineKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
}

/// Line-oriented LCS, with a bounded middle matrix to keep large file reviews
/// responsive. For a large changed region we display the exact old/new blocks.
List<DiffLine> buildLineDiff(String? before, String after) {
  List<String> lines(String value) => const LineSplitter().convert(value);
  final old = lines(before ?? '');
  final next = lines(after);
  var prefix = 0;
  while (prefix < old.length &&
      prefix < next.length &&
      old[prefix] == next[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < old.length - prefix &&
      suffix < next.length - prefix &&
      old[old.length - suffix - 1] == next[next.length - suffix - 1]) {
    suffix++;
  }
  final result = <DiffLine>[
    for (var i = 0; i < prefix; i++)
      DiffLine(DiffLineKind.context, old[i], i + 1, i + 1),
  ];
  final n = old.length - prefix - suffix;
  final m = next.length - prefix - suffix;
  if ((n + 1) * (m + 1) > 250000) {
    for (var i = prefix; i < old.length - suffix; i++) {
      result.add(DiffLine(DiffLineKind.removed, old[i], i + 1, null));
    }
    for (var j = prefix; j < next.length - suffix; j++) {
      result.add(DiffLine(DiffLineKind.added, next[j], null, j + 1));
    }
  } else {
    final table = List.generate(n + 1, (_) => Uint32List(m + 1));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        table[i][j] = old[prefix + i] == next[prefix + j]
            ? table[i + 1][j + 1] + 1
            : (table[i + 1][j] >= table[i][j + 1]
                  ? table[i + 1][j]
                  : table[i][j + 1]);
      }
    }
    var i = 0;
    var j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && old[prefix + i] == next[prefix + j]) {
        result.add(
          DiffLine(
            DiffLineKind.context,
            old[prefix + i],
            prefix + i + 1,
            prefix + j + 1,
          ),
        );
        i++;
        j++;
      } else if (i < n && (j == m || table[i + 1][j] >= table[i][j + 1])) {
        result.add(
          DiffLine(DiffLineKind.removed, old[prefix + i], prefix + i + 1, null),
        );
        i++;
      } else {
        result.add(
          DiffLine(DiffLineKind.added, next[prefix + j], null, prefix + j + 1),
        );
        j++;
      }
    }
  }
  for (var k = 0; k < suffix; k++) {
    result.add(
      DiffLine(
        DiffLineKind.context,
        old[old.length - suffix + k],
        old.length - suffix + k + 1,
        next.length - suffix + k + 1,
      ),
    );
  }
  return result;
}

/// Independently reviewable contiguous changed blocks, indexed in diff order.
List<List<DiffLine>> changedDiffBlocks(String before, String after) {
  final blocks = <List<DiffLine>>[];
  var current = <DiffLine>[];
  for (final line in buildLineDiff(before, after)) {
    if (line.kind == DiffLineKind.context) {
      if (current.isNotEmpty) {
        blocks.add(current);
        current = [];
      }
    } else {
      current.add(line);
    }
  }
  if (current.isNotEmpty) blocks.add(current);
  return blocks;
}

/// Builds the desired whole-file content; caller must still CAS-write against
/// the reviewed afterHash, so an external edit cannot be silently overwritten.
String revertDiffBlocks(String before, String after, Set<int> selected) {
  final blocks = changedDiffBlocks(before, after);
  if (selected.isEmpty) return after;
  if (selected.length == blocks.length &&
      selected.every((i) => i >= 0 && i < blocks.length)) {
    return before;
  }
  List<String> rawLines(String text) => RegExp(r'[^\r\n]*(?:\r\n|\r|\n|$)')
      .allMatches(text)
      .map((m) => m.group(0)!)
      .where((line) => line.isNotEmpty)
      .toList();
  final oldRaw = rawLines(before), newRaw = rawLines(after);
  final output = StringBuffer();
  var block = -1;
  var changing = false;
  for (final line in buildLineDiff(before, after)) {
    if (line.kind == DiffLineKind.context) {
      changing = false;
      output.write(newRaw[line.newLine! - 1]);
      continue;
    }
    if (!changing) {
      block++;
      changing = true;
    }
    final undo = selected.contains(block);
    if (undo && line.kind == DiffLineKind.removed) {
      output.write(oldRaw[line.oldLine! - 1]);
    } else if (!undo && line.kind == DiffLineKind.added) {
      output.write(newRaw[line.newLine! - 1]);
    }
  }
  return output.toString();
}
