import 'dart:async';
import 'dart:io';
import 'dart:isolate';
export 'package:meta/meta.dart';
export 'dart:typed_data';

const kIsWeb = false;
const kReleaseMode = bool.fromEnvironment('dart.vm.product');
const kProfileMode = bool.fromEnvironment('dart.vm.profile');
const kDebugMode = !kReleaseMode && !kProfileMode;

enum TargetPlatform { android, fuchsia, iOS, linux, macOS, windows }

TargetPlatform get defaultTargetPlatform => switch (Platform.operatingSystem) {
  'windows' => TargetPlatform.windows,
  'macos' => TargetPlatform.macOS,
  'ios' => TargetPlatform.iOS,
  'android' => TargetPlatform.android,
  'fuchsia' => TargetPlatform.fuchsia,
  _ => TargetPlatform.linux,
};
typedef VoidCallback = void Function();
typedef ValueChanged<T> = void Function(T value);
void debugPrint(String? message, {int? wrapWidth}) {
  if (message != null) stderr.writeln(message);
}

Future<R> compute<Q, R>(
  FutureOr<R> Function(Q) callback,
  Q message, {
  String? debugLabel,
}) => Isolate.run(() => callback(message), debugName: debugLabel);
bool listEquals<T>(List<T>? a, List<T>? b) =>
    identical(a, b) ||
    a != null &&
        b != null &&
        a.length == b.length &&
        Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
bool mapEquals<K, V>(Map<K, V>? a, Map<K, V>? b) =>
    identical(a, b) ||
    a != null &&
        b != null &&
        a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && a[k] == b[k]);
bool setEquals<T>(Set<T>? a, Set<T>? b) =>
    identical(a, b) ||
    a != null && b != null && a.length == b.length && a.containsAll(b);

abstract interface class Listenable {
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
}

abstract interface class ValueListenable<T> implements Listenable {
  T get value;
}

class ChangeNotifier implements Listenable {
  final _listeners = <VoidCallback>{};
  bool _disposed = false;
  bool get hasListeners => _listeners.isNotEmpty;
  @override
  void addListener(VoidCallback listener) {
    if (_disposed) throw StateError('Disposed');
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
  void notifyListeners() {
    if (_disposed) return;
    for (final listener in _listeners.toList()) {
      if (_listeners.contains(listener)) listener();
    }
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}

class ValueNotifier<T> extends ChangeNotifier implements ValueListenable<T> {
  ValueNotifier(this._value);
  T _value;
  @override
  T get value => _value;
  set value(T next) {
    if (next != _value) {
      _value = next;
      notifyListeners();
    }
  }
}
