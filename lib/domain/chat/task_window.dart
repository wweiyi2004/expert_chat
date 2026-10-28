import 'dart:async';
import 'package:dio/dio.dart';

/// The lifetime of one UI window, shared by its async work and reconnects.
class TaskWindow {
  TaskWindow(this.id);
  final String id;
  static final _zoneKey = Object();
  static TaskWindow? get current => Zone.current[_zoneKey] as TaskWindow?;
  final _tokens = <CancelToken>{};
  bool closed = false;

  T run<T>(T Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: this});

  void ensureOpen() {
    if (closed) throw StateError('窗口已关闭，未启动新任务');
  }

  void Function() attach(CancelToken token) {
    if (closed) {
      token.cancel('窗口已关闭');
    } else {
      _tokens.add(token);
    }
    return () => _tokens.remove(token);
  }

  void close() {
    if (closed) return;
    closed = true;
    for (final token in _tokens.toList()) {
      token.cancel('窗口已关闭');
    }
    _tokens.clear();
  }
}
