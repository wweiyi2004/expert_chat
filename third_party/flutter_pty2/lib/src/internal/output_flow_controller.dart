import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

final class OutputFlowController {
  OutputFlowController({
    required void Function(int bytes) acknowledge,
    required void Function() discardOutput,
    void Function()? onDrained,
    Object? owner,
  })  : _acknowledge = acknowledge,
        _discardOutput = discardOutput,
        _onDrained = onDrained,
        _ownerReference = switch (owner) {
          final owner? => WeakReference(owner),
          null => null,
        } {
    _controller = StreamController<Uint8List>(
      sync: true,
      onListen: _handleListen,
      onPause: _handlePause,
      onResume: _handleResume,
      onCancel: _handleCancel,
    );
  }

  void Function(int bytes) _acknowledge;
  void Function() _discardOutput;
  final void Function()? _onDrained;
  Object? _owner;
  WeakReference<Object>? _ownerReference;
  final Queue<Uint8List> _pending = Queue<Uint8List>();
  late final StreamController<Uint8List> _controller;

  bool _hasListener = false;
  bool _paused = false;
  bool _cancelled = false;
  bool _nativeClosed = false;
  bool _drainedNotified = false;

  Stream<Uint8List> get stream => _controller.stream;

  void setOwner(Object owner) {
    _ownerReference = WeakReference(owner);
  }

  void addNativeOutput(Uint8List bytes) {
    if (_cancelled || _nativeClosed) {
      _acknowledge(bytes.length);
      return;
    }
    if (!_hasListener || _paused) {
      _pending.addLast(bytes);
      return;
    }
    _controller.add(bytes);
    _acknowledge(bytes.length);
  }

  void handleNativeClosed() {
    _nativeClosed = true;
    _drain();
  }

  Future<void> close() async {
    _nativeClosed = true;
    _drain();
    await _controller.close();
  }

  void closeAndDiscard() {
    _cancelled = true;
    _owner = null;
    while (_pending.isNotEmpty) {
      _acknowledge(_pending.removeFirst().length);
    }
    _discardOutput();
    _acknowledge = (_) {};
    _discardOutput = () {};
    _nativeClosed = true;
    _notifyDrained();
    if (!_controller.isClosed) unawaited(_controller.close());
  }

  void _handleListen() {
    _owner = _ownerReference?.target;
    _hasListener = true;
    _drain();
  }

  void _handlePause() {
    _paused = true;
  }

  void _handleResume() {
    _paused = false;
    _drain();
  }

  Future<void> _handleCancel() async {
    _cancelled = true;
    final owner = _owner;
    if (owner != null) _owner = null;
    while (_pending.isNotEmpty) {
      _acknowledge(_pending.removeFirst().length);
    }
    _discardOutput();
    _notifyDrained();
  }

  void _drain() {
    while (_hasListener && !_paused && !_cancelled && _pending.isNotEmpty) {
      final bytes = _pending.removeFirst();
      _controller.add(bytes);
      _acknowledge(bytes.length);
    }
    _notifyDrained();
    if (_nativeClosed && _pending.isEmpty && !_controller.isClosed) {
      unawaited(_controller.close());
    }
  }

  void _notifyDrained() {
    if (!_nativeClosed || _pending.isNotEmpty || _drainedNotified) return;
    _drainedNotified = true;
    _onDrained?.call();
  }
}
