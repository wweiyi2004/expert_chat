import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_pty2/src/generated/flutter_pty_bindings_generated.dart'
    as native;
import 'package:flutter_pty2/src/internal/input_flow_controller.dart';
import 'package:flutter_pty2/src/internal/native_event.dart';
import 'package:flutter_pty2/src/internal/native_event_pump.dart';
import 'package:flutter_pty2/src/internal/output_flow_controller.dart';
import 'package:flutter_pty2/src/internal/pty_capabilities_codec.dart';
import 'package:flutter_pty2/src/pty_capabilities.dart';
import 'package:flutter_pty2/src/pty_exception.dart';
import 'package:flutter_pty2/src/pty_exit.dart';
import 'package:flutter_pty2/src/pty_input.dart';
import 'package:flutter_pty2/src/pty_session.dart';
import 'package:flutter_pty2/src/pty_size.dart';

final class FfiPtySessionState implements NativeEventHandler {
  FfiPtySessionState({
    required this.handle,
    required this.bindings,
    int inputBufferBytes = 1024 * 1024,
    void Function()? onAsyncError,
  }) {
    _onAsyncError = onAsyncError;
    _output = OutputFlowController(
      acknowledge: _acknowledgeOutput,
      discardOutput: _discardOutput,
      onDrained: _handleOutputDrained,
    );
    _input = InputFlowController(
      nativeTryWrite: _tryWrite,
      maxPendingBytes: inputBufferBytes,
    );
    _observeLifecycleErrors();
  }

  final Pointer<native.PtySession> handle;
  final native.FlutterPtyBindings bindings;
  late final void Function()? _onAsyncError;
  final _spawnCompleter = Completer<void>();
  final _processExitCompleter = Completer<PtyExit>();
  final _doneCompleter = Completer<PtyExit>();
  final _closedCompleter = Completer<void>();
  late final OutputFlowController _output;
  late final InputFlowController _input;
  PtyExit? _processExit;
  PtyCapabilities? _capabilities;
  bool _outputClosed = false;
  bool _outputDrained = false;
  bool _protocolFailed = false;
  bool _fatalErrorHandled = false;

  void _observeLifecycleErrors() {
    unawaited(_spawnCompleter.future.then<void>((_) {}, onError: (_, __) {}));
    unawaited(
      _processExitCompleter.future.then<void>((_) {}, onError: (_, __) {}),
    );
    unawaited(_doneCompleter.future.then<void>((_) {}, onError: (_, __) {}));
  }

  OutputFlowController get output => _output;

  InputFlowController get input => _input;

  Future<void> get spawned => _spawnCompleter.future;

  Future<PtyExit> get processExit => _processExitCompleter.future;

  Future<PtyExit> get done => _doneCompleter.future;

  Future<void> get closed => _closedCompleter.future;

  PtyCapabilities get capabilities {
    final capabilities = _capabilities;
    if (capabilities == null) {
      throw StateError('PTY capabilities are unavailable before spawn');
    }
    return capabilities;
  }

  void _acknowledgeOutput(int bytes) {
    bindings.pty_session_ack_output(handle, bytes);
  }

  void _discardOutput() {
    bindings.pty_session_discard_output(handle);
  }

  void _handleOutputDrained() {
    _outputDrained = true;
    _maybeCompleteDone();
  }

  @override
  void handleNativeEvent(NativeEvent event) {
    switch (event) {
      case NativeSpawned(:final capabilities):
        _capabilities ??= decodePtyCapabilities(capabilities);
        if (!_spawnCompleter.isCompleted) _spawnCompleter.complete();
      case NativeSpawnFailed(:final error):
        _handleSpawnFailure(error);
      case NativeOutput(:final bytes):
        _output.addNativeOutput(bytes);
      case NativeOutputClosed():
        if (_outputClosed) return;
        _outputClosed = true;
        _output.handleNativeClosed();
        _maybeCompleteDone();
      case NativeWriteComplete(:final requestId):
        _input.handleWriteComplete(requestId);
      case NativeWritable():
        _input.handleWritable();
      case NativeInputClosed(:final error):
        _input.handleClosed(
            PtyIoException('PTY input closed', nativeError: error));
      case NativeProcessExit(:final exit):
        if (_processExit != null || _processExitCompleter.isCompleted) return;
        _processExit = exit;
        _processExitCompleter.complete(exit);
        _maybeCompleteDone();
      case NativeAsyncError(:final error):
        _handleAsyncError(error);
      case NativeSessionClosed():
        if (!_closedCompleter.isCompleted) _closedCompleter.complete();
    }
  }

  @override
  void handleProtocolError(String message, {bool sessionClosed = false}) {
    if (_protocolFailed) {
      if (sessionClosed && !_closedCompleter.isCompleted) {
        _closedCompleter.complete();
      }
      return;
    }
    _protocolFailed = true;
    final error = StateError(message);
    if (!_spawnCompleter.isCompleted) _spawnCompleter.completeError(error);
    if (!_processExitCompleter.isCompleted) {
      _processExitCompleter.completeError(error);
    }
    if (!_doneCompleter.isCompleted) _doneCompleter.completeError(error);
    _input.handleClosed(error);
    _output.closeAndDiscard();
    if (sessionClosed && !_closedCompleter.isCompleted) {
      _closedCompleter.complete();
    }
    bindings.pty_session_begin_close(handle);
  }

  void _handleAsyncError(PtyNativeError nativeError) {
    if (_fatalErrorHandled) return;
    _fatalErrorHandled = true;
    final error = PtyIoException('PTY I/O failed', nativeError: nativeError);
    _failLifecycle(error);
    _onAsyncError?.call();
  }

  void _handleSpawnFailure(PtyNativeError nativeError) {
    if (_fatalErrorHandled) return;
    _fatalErrorHandled = true;
    final error = PtySpawnException(
      'PTY process failed to spawn',
      nativeError: nativeError,
    );
    _failLifecycle(error);
    _onAsyncError?.call();
  }

  void _failLifecycle(Object error) {
    if (!_spawnCompleter.isCompleted) _spawnCompleter.completeError(error);
    _input.handleClosed(error);
    if (!_processExitCompleter.isCompleted) {
      _processExitCompleter.completeError(error);
    }
    if (!_doneCompleter.isCompleted) _doneCompleter.completeError(error);
  }

  void _maybeCompleteDone() {
    final exit = _processExit;
    if (exit == null ||
        !_outputClosed ||
        !_outputDrained ||
        _doneCompleter.isCompleted) {
      return;
    }
    _doneCompleter.complete(exit);
  }

  PtyWriteResult _tryWrite(int requestId, Uint8List data) {
    return using((arena) {
      final nativeBytes = arena<Uint8>(data.length);
      nativeBytes.asTypedList(data.length).setAll(0, data);
      final error = arena<native.PtyError>();
      final result = bindings.pty_session_try_write(
        handle,
        requestId,
        nativeBytes,
        data.length,
        error,
      );
      if (result == native.PtyTryWriteResult.PTY_WRITE_ERROR) {
        final exception = PtyIoException(
          'Writing to PTY failed',
          nativeError: readNativeError(error.ref),
        );
        bindings.pty_session_begin_close(handle);
        throw exception;
      }
      return switch (result) {
        native.PtyTryWriteResult.PTY_WRITE_ACCEPTED => PtyWriteResult.accepted,
        native.PtyTryWriteResult.PTY_WRITE_BACKPRESSURED =>
          PtyWriteResult.backpressured,
        _ => PtyWriteResult.closed,
      };
    });
  }
}

final class FfiPtySession implements PtySession, Finalizable {
  FfiPtySession({
    required this.handle,
    required this.bindings,
    required this.port,
    required int inputBufferBytes,
    required NativeFinalizer finalizer,
  })  : _finalizer = finalizer,
        _state = FfiPtySessionState(
          handle: handle,
          bindings: bindings,
          inputBufferBytes: inputBufferBytes,
          onAsyncError: () => bindings.pty_session_begin_close(handle),
        );

  final Pointer<native.PtySession> handle;
  final native.FlutterPtyBindings bindings;
  final ReceivePort port;
  final NativeFinalizer _finalizer;
  final FfiPtySessionState _state;
  final _finalizerDetachToken = Object();
  late final NativeEventPump _eventPump;
  bool _closing = false;
  bool _finalizerDetached = false;
  Future<void>? _closeFuture;

  @override
  int get pid {
    _ensureOpen();
    return bindings.pty_session_pid(handle).toInt();
  }

  @override
  PtyCapabilities get capabilities => _state.capabilities;

  @override
  Stream<Uint8List> get output {
    _state.output.setOwner(this);
    return _state.output.stream;
  }

  @override
  PtyInput get input {
    _state.input.setOwner(this);
    return _state.input;
  }

  @override
  Future<PtyExit> get processExit =>
      _state.processExit.then(_retainSessionUntilFutureCompletes);

  @override
  Future<PtyExit> get done =>
      _state.done.then(_retainSessionUntilFutureCompletes);

  void attach() {
    _eventPump = NativeEventPump(port)..attach(_state);
    _finalizer.attach(
      this,
      handle.cast(),
      detach: _finalizerDetachToken,
    );
  }

  Future<PtySession> waitForSpawn() async {
    await _state.spawned;
    return this;
  }

  PtyExit _retainSessionUntilFutureCompletes(PtyExit exit) => exit;

  @override
  void resize(PtySize size) {
    _ensureOpen();
    size.validate();
    using((arena) {
      final nativeSize = arena<native.PtySize>();
      nativeSize.ref
        ..rows = size.rows
        ..columns = size.columns
        ..pixel_width = size.pixelWidth
        ..pixel_height = size.pixelHeight;
      final error = arena<native.PtyError>();
      final result = bindings.pty_session_resize(handle, nativeSize.ref, error);
      if (result == 0) {
        throw PtyIoException('Resizing PTY failed',
            nativeError: readNativeError(error.ref));
      }
    });
  }

  @override
  void kill() {
    _ensureOpen();
    using((arena) {
      final error = arena<native.PtyError>();
      final result = bindings.pty_session_kill(handle, error);
      if (result == 0) {
        throw PtyIoException('Killing PTY failed',
            nativeError: readNativeError(error.ref));
      }
    });
  }

  @override
  void sendSignal(PosixSignal signal,
      {PosixSignalTarget target = PosixSignalTarget.foregroundProcessGroup}) {
    _ensureOpen();
    if (Platform.isWindows) {
      throw const PtyUnsupportedException(
        'POSIX signals are unsupported on Windows',
      );
    }
    using((arena) {
      final error = arena<native.PtyError>();
      final result = bindings.pty_session_send_signal(
        handle,
        signal.number,
        target.index,
        error,
      );
      if (result == 0) {
        throw PtyIoException('Sending POSIX signal failed',
            nativeError: readNativeError(error.ref));
      }
    });
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final closeFuture = _close();
    _closeFuture = closeFuture;
    return closeFuture;
  }

  Future<void> _close() async {
    _closing = true;
    _state.input.closeWithError(const PtyClosedException());
    bindings.pty_session_begin_close(handle);
    await _state.closed;
    _state.output.closeAndDiscard();
    if (!_finalizerDetached) {
      _finalizer.detach(_finalizerDetachToken);
      _finalizerDetached = true;
      bindings.pty_session_release(handle);
    }
    await _eventPump.close();
  }

  void _ensureOpen() {
    if (_closing) throw const PtyClosedException();
  }
}

PtyNativeError readNativeError(native.PtyError error) {
  final codeUnits = <int>[];
  for (var index = 0; index < 256; index++) {
    final value = error.message[index];
    if (value == 0) break;
    codeUnits.add(value);
  }
  final domain = _enumValue(PtyErrorDomain.values, error.domain);
  final kind = _enumValue(PtyErrorKind.values, error.kind);
  return PtyNativeError(
    domain: domain,
    kind: kind,
    code: error.os_code,
    message: String.fromCharCodes(codeUnits),
  );
}

T _enumValue<T>(List<T> values, int index) {
  if (index <= 0 || index > values.length) {
    throw StateError('Unknown native enum value: $index');
  }
  return values[index - 1];
}
