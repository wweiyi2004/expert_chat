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
