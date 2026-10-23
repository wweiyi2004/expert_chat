import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_pty2/src/generated/flutter_pty_bindings_generated.dart'
    as native;
import 'package:flutter_pty2/src/internal/ffi_session.dart';
import 'package:flutter_pty2/src/internal/native_library.dart';
import 'package:flutter_pty2/src/pty_environment.dart';
import 'package:flutter_pty2/src/pty_exception.dart';
import 'package:flutter_pty2/src/pty_session.dart';
import 'package:flutter_pty2/src/pty_spawn_options.dart';

final class FfiPtyDriver {
  FfiPtyDriver._();

  static final instance = FfiPtyDriver._();
  static final DynamicLibrary _library = openPtyLibrary();
  static final native.FlutterPtyBindings _bindings =
      native.FlutterPtyBindings(_library);
  static final NativeFinalizer _sessionFinalizer = NativeFinalizer(
    _library.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
      'pty_session_abandon',
    ),
  );
  static bool _initialized = false;

  Future<PtySession> spawn(PtySpawnOptions options) async {
    options.validate();
    _ensureInitialized();

    final environment = buildEnvironment(
      options.environment,
      caseInsensitive: Platform.isWindows,
    );
    final port = ReceivePort();
    late final Pointer<native.PtySession> nativeSession;
    try {
      nativeSession = using((arena) {
        final nativeOptions = arena.allocate<native.PtySpawnOptions>(
          sizeOf<native.PtySpawnOptions>(),
        );
        final executable = options.executable.toNativeUtf8(allocator: arena);
        final arguments = arena<Pointer<Char>>(options.arguments.length + 1);
        for (var index = 0; index < options.arguments.length; index++) {
          (arguments + index).value =
              options.arguments[index].toNativeUtf8(allocator: arena).cast();
        }
        (arguments + options.arguments.length).value = nullptr;

        final environmentValues = environment.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .toList(growable: false);
        final environmentPointers =
            arena<Pointer<Char>>(environmentValues.length + 1);
        for (var index = 0; index < environmentValues.length; index++) {
          (environmentPointers + index).value =
              environmentValues[index].toNativeUtf8(allocator: arena).cast();
        }
        (environmentPointers + environmentValues.length).value = nullptr;

        nativeOptions.ref
          ..executable = executable.cast()
          ..arguments = arguments
          ..argument_count = options.arguments.length
          ..environment = environmentPointers
          ..environment_count = environmentValues.length
          ..working_directory = switch (options.workingDirectory) {
            final directory? => directory.toNativeUtf8(allocator: arena).cast(),
            null => nullptr,
          }
          ..input_buffer_bytes = options.inputBufferBytes
          ..output_window_bytes = options.outputWindowBytes
          ..event_port = port.sendPort.nativePort;
        nativeOptions.ref.size
          ..rows = options.size.rows
          ..columns = options.size.columns
          ..pixel_width = options.size.pixelWidth
          ..pixel_height = options.size.pixelHeight;

        final outSession = arena<Pointer<native.PtySession>>();
        final outError = arena<native.PtyError>();
        final result = _bindings.pty_session_start(
          nativeOptions,
          outSession,
          outError,
        );
        if (result == 0 || outSession.value == nullptr) {
          throw PtySpawnException(
            'Starting PTY session failed',
            nativeError: readNativeError(outError.ref),
          );
        }
        return outSession.value;
      });
    } catch (_) {
      port.close();
      rethrow;
    }

    final session = FfiPtySession(
      handle: nativeSession,
      bindings: _bindings,
      port: port,
      inputBufferBytes: options.inputBufferBytes,
      finalizer: _sessionFinalizer,
    );
    session.attach();
    try {
      return await session.waitForSpawn();
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  void _ensureInitialized() {
    if (_initialized) return;
    final result = _bindings.Dart_InitializeApiDL(
      NativeApi.initializeApiDLData.cast(),
    );
    if (result != 0) {
      throw StateError('Failed to initialize native PTY bindings');
    }
    _initialized = true;
  }
}
