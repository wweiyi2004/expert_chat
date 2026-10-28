import 'package:flutter/foundation.dart';

/// Adapts core change streams to Flutter without making the core a Widget API.
final _adapters = Expando<Listenable>();
Listenable runtimeListenable(Object source) {
  if (source is Listenable) return source;
  return _adapters[source] ??= _RuntimeListenable(source);
}

class _RuntimeListenable implements Listenable {
  _RuntimeListenable(this.source);
  final dynamic source;
  @override
  void addListener(VoidCallback listener) => source.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => source.removeListener(listener);
}
