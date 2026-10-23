import 'dart:io';

sealed class PtyEnvironment {
  const PtyEnvironment();

  const factory PtyEnvironment.inherit({
    Map<String, String> overrides,
    Set<String> remove,
  }) = PtyInheritedEnvironment;

  const factory PtyEnvironment.replace(
    Map<String, String> values,
  ) = PtyReplacedEnvironment;

  void validate();
}

final class PtyInheritedEnvironment extends PtyEnvironment {
  const PtyInheritedEnvironment({
    this.overrides = const {},
    this.remove = const {},
  });

  final Map<String, String> overrides;
  final Set<String> remove;

  @override
  void validate() {
    _validateEntries(overrides.entries);
    for (final key in remove) {
      _validateKey(key);
    }
  }
}

final class PtyReplacedEnvironment extends PtyEnvironment {
  const PtyReplacedEnvironment(this.values);

  final Map<String, String> values;

  @override
  void validate() {
    _validateEntries(values.entries);
  }
}

Map<String, String> buildEnvironment(
  PtyEnvironment environment, {
  required bool caseInsensitive,
}) {
  environment.validate();
  final result = <String, String>{};

  String normalize(String key) {
    if (caseInsensitive) return key.toUpperCase();
    return key;
  }

  switch (environment) {
    case PtyInheritedEnvironment(:final overrides, :final remove):
      for (final entry in Platform.environment.entries) {
        result[normalize(entry.key)] = entry.value;
      }
      for (final key in remove) {
        result.remove(normalize(key));
      }
      for (final entry in overrides.entries) {
        result[normalize(entry.key)] = entry.value;
      }
    case PtyReplacedEnvironment(:final values):
      for (final entry in values.entries) {
        result[normalize(entry.key)] = entry.value;
      }
  }

  if (!caseInsensitive) return result;

  final entries = result.entries.toList(growable: false)
    ..sort((first, second) => first.key.compareTo(second.key));
  return Map<String, String>.fromEntries(entries);
}

void _validateEntries(Iterable<MapEntry<String, String>> entries) {
  for (final entry in entries) {
    _validateKey(entry.key);
    if (entry.value.contains('\x00')) {
      throw ArgumentError.value(
        entry.value,
        'environment value for ${entry.key}',
        'must not contain NUL bytes',
      );
    }
  }
}

void _validateKey(String key) {
  if (key.isEmpty) {
    throw ArgumentError.value(key, 'environment key', 'must not be empty');
  }
  if (key.contains('=') || key.contains('\x00')) {
    throw ArgumentError.value(
      key,
      'environment key',
      'must not contain = or NUL bytes',
    );
  }
}
