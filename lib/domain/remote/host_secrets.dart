import 'dart:math';

class HostSecrets {
  HostSecrets(this.values);
  final List<String> Function() values;
  List<String> get _known =>
      values().where((value) => value.isNotEmpty).toSet().toList();
  String redact(String input) {
    var text = input;
    for (final secret in _known..sort((a, b) => b.length.compareTo(a.length))) {
      text = text.replaceAll(secret, '[REDACTED]');
    }
    return text;
  }

  Object? sanitize(Object? value) {
    if (value is String) return redact(value);
    if (value is List) return value.map(sanitize).toList();
    if (value is Map) {
      return {
        for (final entry in value.entries)
          redact(entry.key.toString()): sanitize(entry.value),
      };
    }
    return value;
  }

  Map<String, String> childEnvironment(Map<String, String> parent) => {
    for (final entry in parent.entries)
      if (!entry.key.toUpperCase().startsWith('EXPERT_REMOTE_') &&
          !_known.any((secret) => entry.value.contains(secret)))
        entry.key: entry.value,
  };
  Stream<String> protect(Stream<String> input) async* {
    final hold =
        _known.fold<int>(0, (size, value) => max(size, value.length)) - 1;
    var pending = '';
    await for (final chunk in input) {
      pending += chunk;
      var cut = max(0, pending.length - max(0, hold)).toInt();
      var changed = true;
      while (changed) {
        changed = false;
        for (final secret in _known) {
          var start = pending.indexOf(secret);
          while (start >= 0) {
            if (start < cut && start + secret.length > cut) {
              cut = start;
              changed = true;
            }
            start = pending.indexOf(secret, start + 1);
          }
        }
      }
      if (cut > 0) {
        yield redact(pending.substring(0, cut));
        pending = pending.substring(cut);
      }
    }
    if (pending.isNotEmpty) yield redact(pending);
  }
}
