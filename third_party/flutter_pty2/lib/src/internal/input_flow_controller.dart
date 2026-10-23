import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_pty2/src/pty_exception.dart';
import 'package:flutter_pty2/src/pty_input.dart';

final class InputFlowController implements PtyInput {
  InputFlowController({
    required this.nativeTryWrite,
    this.maxChunkSize = 64 * 1024,
    this.maxPendingBytes = 1024 * 1024,
  }) {
    if (maxChunkSize <= 0) {
      throw ArgumentError.value(
        maxChunkSize,
        'maxChunkSize',
        'must be positive',
      );
    }
    if (maxPendingBytes <= 0) {
      throw ArgumentError.value(
        maxPendingBytes,
        'maxPendingBytes',
        'must be positive',
      );
    }
  }

  final PtyWriteResult Function(int requestId, Uint8List bytes) nativeTryWrite;
  final int maxChunkSize;
  final int maxPendingBytes;
  Object? _owner;
  WeakReference<Object>? _ownerReference;

  void setOwner(Object owner) {
    _ownerReference = WeakReference(owner);
  }

  final Queue<_WriteRequest> _admissions = Queue<_WriteRequest>();
  final Queue<_WriteRequest> _waiting = Queue<_WriteRequest>();
  final Map<int, _PendingWrite> _inflight = <int, _PendingWrite>{};

  int _nextRequestId = 1;
  int _ownedPendingBytes = 0;
  bool _waitingForWritable = false;
  bool _closed = false;

  /// Bytes copied into pending Dart/native write storage.
  int get debugOwnedPendingBytes => _ownedPendingBytes;

  @override
  Future<void> write(Uint8List data) async {
    if (_closed) throw const PtyClosedException();
    if (data.isEmpty) return;

    _retainOwner();
    final request = _WriteRequest(data);
    _admissions.addLast(request);
    _pumpAdmissions();
    try {
      await request.completer.future;
    } finally {
      _releaseOwnerIfIdle();
    }
  }

  @override
  PtyWriteResult tryWrite(Uint8List data) {
    if (_closed) return PtyWriteResult.closed;
    if (data.isEmpty) return PtyWriteResult.accepted;
    if (data.length > maxChunkSize) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'tryWrite accepts at most $maxChunkSize bytes',
      );
    }
    if (_admissions.isNotEmpty || _waiting.isNotEmpty || _waitingForWritable) {
      return PtyWriteResult.backpressured;
    }
    if (data.length > maxPendingBytes - _ownedPendingBytes) {
      return PtyWriteResult.backpressured;
    }

    _retainOwner();
    final id = _nextRequestId++;
    PtyWriteResult result;
    try {
      result = nativeTryWrite(id, data);
      if (result == PtyWriteResult.accepted) {
        _ownedPendingBytes += data.length;
        final pending = _PendingWrite(id: id, bytes: data.length);
        _inflight[id] = pending;
        unawaited(pending.completer.future.catchError((Object _) {}));
      }
    } catch (error, stackTrace) {
      closeWithError(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (result == PtyWriteResult.closed) {
      closeWithError(const PtyClosedException());
    }
    _releaseOwnerIfIdle();
    return result;
  }

  @override
  Future<void> flush() {
    final futures = <Future<void>>[
      for (final request in _admissions) request.completer.future,
      for (final request in _waiting) request.completer.future,
      for (final pending in _inflight.values)
        if (pending.request == null) pending.completer.future,
    ];
    return Future.wait(futures);
  }

  void handleWritable() {
    if (_closed) return;
    _waitingForWritable = false;
    _pump();
    _releaseOwnerIfIdle();
  }

  void handleWriteComplete(int requestId) {
    final pending = _inflight.remove(requestId);
    if (pending == null) return;
    _ownedPendingBytes -= pending.bytes;
    final request = pending.request;
    switch (request) {
      case null:
        if (!pending.completer.isCompleted) pending.completer.complete();
      case final request:
        request.inflightBytes -= pending.bytes;
        if (request.offset >= request.data.length &&
            request.inflightBytes == 0) {
          if (_waiting.isNotEmpty && identical(_waiting.first, request)) {
            _waiting.removeFirst();
          }
          if (!request.completer.isCompleted) {
            request.completer.complete();
          }
          _pumpAdmissions();
        }
    }
    _pump();
    _releaseOwnerIfIdle();
  }

  void handleClosed(Object error) {
    closeWithError(error, StackTrace.current);
  }

  void closeWithError(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _closed = true;
    for (final request in _admissions) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error, stackTrace);
      }
    }
    _admissions.clear();
    for (final request in _waiting) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error, stackTrace);
      }
    }
    for (final pending in _inflight.values) {
      if (pending.request == null && !pending.completer.isCompleted) {
        pending.completer.completeError(error, stackTrace);
      }
    }
    _waiting.clear();
    _inflight.clear();
    _ownedPendingBytes = 0;
    _owner = null;
  }

  void _pumpAdmissions() {
    if (_closed) return;
    while (_admissions.isNotEmpty) {
      final request = _admissions.first;
      if (_waiting.isNotEmpty || _ownedPendingBytes >= maxPendingBytes) {
        return;
      }
      _admissions.removeFirst();
      _waiting.addLast(request);
      _pump();
      if (_waiting.isNotEmpty && identical(_waiting.first, request)) return;
    }
  }

  void _pump() {
    if (_closed || _waitingForWritable) return;
    while (_waiting.isNotEmpty) {
      final request = _waiting.first;
      if (request.offset >= request.data.length) {
        if (request.inflightBytes == 0) {
          _waiting.removeFirst();
          if (!request.completer.isCompleted) request.completer.complete();
          continue;
        }
        return;
      }
      final available = maxPendingBytes - _ownedPendingBytes;
      if (available == 0) return;
      final end = math.min(
        request.offset + maxChunkSize,
        math.min(request.data.length, request.offset + available),
      );
      final length = end - request.offset;
      final chunk = Uint8List(length)
        ..setRange(0, length, request.data, request.offset);
      final requestId = request.retryRequestId ??= _nextRequestId++;
      PtyWriteResult result;
      try {
        result = nativeTryWrite(requestId, chunk);
      } catch (error, stackTrace) {
        closeWithError(error, stackTrace);
        return;
      }
      switch (result) {
        case PtyWriteResult.accepted:
          request.retryRequestId = null;
          request.offset = end;
          request.inflightBytes += length;
          _ownedPendingBytes += length;
          _inflight[requestId] = _PendingWrite(
            id: requestId,
            request: request,
            bytes: length,
          );
        case PtyWriteResult.backpressured:
          _waitingForWritable = true;
          return;
        case PtyWriteResult.closed:
          closeWithError(const PtyClosedException());
          return;
      }
    }
  }

  void _retainOwner() {
    _owner = _ownerReference?.target;
  }

  void _releaseOwnerIfIdle() {
    final owner = _owner;
    if (owner == null) return;
    if (_admissions.isEmpty && _waiting.isEmpty && _inflight.isEmpty) {
      _owner = null;
    }
  }
}

final class _WriteRequest {
  _WriteRequest(this.data);

  final Uint8List data;
  final completer = Completer<void>();
  int offset = 0;
  int inflightBytes = 0;
  int? retryRequestId;
}

final class _PendingWrite {
  _PendingWrite({required this.id, required this.bytes, this.request});

  final int id;
  final int bytes;
  final _WriteRequest? request;
  final completer = Completer<void>();
}
