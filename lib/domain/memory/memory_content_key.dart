/// Shared equality rule for saved, candidate and imported memory content.
String memoryContentKey(String value) {
  // Keep English word boundaries; spaces next to CJK characters are formatting.
  final collapsed = value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  final cjk = RegExp(r'[㐀-鿿]');
  final result = StringBuffer();
  for (var i = 0; i < collapsed.length; i++) {
    final char = collapsed[i];
    final spaceTouchesCjk =
        char == ' ' &&
        ((i > 0 && cjk.hasMatch(collapsed[i - 1])) ||
            (i + 1 < collapsed.length && cjk.hasMatch(collapsed[i + 1])));
    if (!spaceTouchesCjk) result.write(char);
  }
  return result.toString();
}
