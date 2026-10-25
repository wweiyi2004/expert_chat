/// Quarantine a raw tool envelope mistakenly sent as assistant text. This is
/// not a tool parser: only structured API tool calls may reach the executor.
class ToolMarkupFilter {
  static const _openers = [
    '<｜｜DSML｜｜ calls>',
    '<｜DSML｜ calls>',
    '<||DSML|| calls>',
    '<|DSML| calls>',
  ];
  String _pending = '';
  bool _plainText = false;
  bool detected = false;

  String add(String delta) {
    if (detected) return '';
    if (_plainText) return delta;
    _pending += delta;
    final leading = _pending.trimLeft();
    if (_openers.any(leading.startsWith)) {
      detected = true;
      _pending = '';
      return '';
    }
    if (_openers.any((opener) => opener.startsWith(leading)) &&
        _pending.length < 128) {
      return '';
    }
    _plainText = true;
    final result = _pending;
    _pending = '';
    return result;
  }

  String finish() {
    final result = _pending;
    _pending = '';
    return detected ? '' : result;
  }
}
