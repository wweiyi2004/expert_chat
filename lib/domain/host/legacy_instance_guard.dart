import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

final _createMutex = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<
      IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>),
      int Function(Pointer<Void>, int, Pointer<Utf16>)
    >('CreateMutexW');

class LegacyInstanceGuard {
  int _handle = 0;
  void acquire({
    String name = r'Local\com.wweiyi.expert_chat.single-instance.v1',
  }) {
    if (!Platform.isWindows) return;
    final handle = using(
      (arena) => _createMutex(nullptr, 0, name.toNativeUtf16(allocator: arena)),
    );
    final error = GetLastError();
    if (handle == 0) throw StateError('无法建立旧版写入保护');
    if (error == ERROR_ALREADY_EXISTS) {
      CloseHandle(handle);
      throw StateError('旧版后台或另一宿主仍在运行，请先结束旧任务并退出。');
    }
    _handle = handle;
  }

  void close() {
    if (_handle != 0) {
      CloseHandle(_handle);
      _handle = 0;
    }
  }
}
