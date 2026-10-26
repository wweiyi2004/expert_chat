import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/data/atomic_windows_preferences_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

typedef _CreateNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateDart =
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);

class _ExplicitWindowsMock extends SharedPreferencesWindows {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File file;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('expert-atomic-prefs-');
    file = File('${root.path}/shared_preferences.json');
  });
  tearDown(() async {
    final absolute = await root.resolveSymbolicLinks();
    final base = await Directory.systemTemp.resolveSymbolicLinks();
    if (!p.isWithin(base, absolute) ||
        !p.basename(absolute).startsWith('expert-atomic-prefs-')) {
      throw StateError('cleanup target');
    }
    await root.delete(recursive: true);
  });
  test(
    'same JSON keys prefix filters and list copies survive durable mutation queue',
    () async {
      await file.writeAsString(
        jsonEncode({
          'flutter.a': 1,
          'flutter.b': 2,
          'other.x': 3,
          'flutter.list': ['x'],
        }),
      );
      final gate = Completer<void>();
      var writes = 0;
      final store = await AtomicWindowsPreferencesStore.open(
        file,
        writeTemporary: (f, bytes) async {
          if (++writes == 1) await gate.future;
          await f.writeAsBytes(bytes, flush: true);
        },
      );
      final first = store.setValue('String', 'flutter.a', 'updated');
      final second = store.remove('flutter.b');
      final third = store.clearWithParameters(
        ClearParameters(
          filter: PreferencesFilter(
            prefix: 'flutter.',
            allowList: {'flutter.list'},
          ),
        ),
      );
      gate.complete();
      expect(await Future.wait([first, second, third]), everyElement(true));
      expect(jsonDecode(await file.readAsString()), {
        'flutter.a': 'updated',
        'other.x': 3,
      });
      expect(await store.getAll(), {'flutter.a': 'updated'});
      expect(await store.getAllWithPrefix('other.'), {'other.x': 3});
    },
  );
  test(
    'partial temporary write failure never truncates destination and cached desired values recover',
    () async {
      const original = '{"flutter.original":"keep"}';
      await file.writeAsString(original);
      var fail = true;
      final store = await AtomicWindowsPreferencesStore.open(
        file,
        writeTemporary: (f, bytes) async {
          if (fail) {
            await f.writeAsString('partial');
            throw const FileSystemException('injected partial write');
          }
          await f.writeAsBytes(bytes, flush: true);
        },
      );
      expect(await store.setValue('String', 'flutter.new', 'desired'), false);
      expect(await file.readAsString(), original);
      expect((await store.getAll())['flutter.new'], 'desired');
      expect(await root.list().length, 1);
      fail = false;
      expect(await store.setValue('String', 'flutter.new', 'desired'), true);
      expect(jsonDecode(await file.readAsString()), {
        'flutter.original': 'keep',
        'flutter.new': 'desired',
      });
    },
  );
  test(
    'failed replacement preserves original and unrelated backup and removes only own temp',
    () async {
      const original = '{"flutter.keep":true}';
      await file.writeAsString(original);
      final backup = File('${file.path}.private-backup');
      await backup.writeAsString('untouched');
      final store = await AtomicWindowsPreferencesStore.open(
        file,
        replace: (a, b) async =>
            throw const FileSystemException('injected replacement failure'),
      );
      expect(await store.remove('flutter.keep'), false);
      expect(await file.readAsString(), original);
      expect(await backup.readAsString(), 'untouched');
      expect(await root.list().length, 2);
    },
  );
  test(
    'Windows destination deny-delete lock causes false and leaves original bytes exact',
    () async {
      const original = '{"flutter.keep":"original"}';
      await file.writeAsString(original);
      final store = await AtomicWindowsPreferencesStore.open(file);
      final kernel = DynamicLibrary.open('kernel32.dll');
      final create = kernel.lookupFunction<_CreateNative, _CreateDart>(
        'CreateFileW',
      );
      final close = kernel
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle',
          );
      final name = file.path.toNativeUtf16();
      final handle = create(name, 0x80000000, 1, nullptr, 3, 0, 0);
      calloc.free(name);
      expect(handle, isNot(-1));
      try {
        expect(await store.setValue('String', 'flutter.new', 'value'), false);
        expect(await file.readAsString(), original);
      } finally {
        close(handle);
      }
      expect(await store.setValue('String', 'flutter.new', 'value'), true);
      expect(
        (jsonDecode(await file.readAsString()) as Map)['flutter.keep'],
        'original',
      );
    },
    skip: !Platform.isWindows,
  );
  test(
    'zero or malformed existing files fail closed without rewriting',
    () async {
      for (final text in ['', '{broken']) {
        await file.writeAsString(text);
        await expectLater(
          AtomicWindowsPreferencesStore.open(file),
          throwsA(anything),
        );
        expect(await file.readAsString(), text);
      }
    },
  );
  test(
    'main installer is idempotent and preserves explicit Windows mock subclasses',
    () async {
      final old = SharedPreferencesStorePlatform.instance;
      try {
        final mock = _ExplicitWindowsMock();
        SharedPreferencesStorePlatform.instance = mock;
        await installAtomicWindowsPreferences();
        expect(SharedPreferencesStorePlatform.instance, same(mock));
        final atomic = await AtomicWindowsPreferencesStore.open(file);
        SharedPreferencesStorePlatform.instance = atomic;
        await installAtomicWindowsPreferences();
        expect(SharedPreferencesStorePlatform.instance, same(atomic));
      } finally {
        SharedPreferencesStorePlatform.instance = old;
        SharedPreferences.resetStatic();
      }
    },
  );
  test('main installer preserves an explicit mock store', () async {
    final old = SharedPreferencesStorePlatform.instance;
    try {
      SharedPreferences.setMockInitialValues({'keep': 'mock'});
      final mock = SharedPreferencesStorePlatform.instance;
      await installAtomicWindowsPreferences();
      expect(SharedPreferencesStorePlatform.instance, same(mock));
    } finally {
      SharedPreferencesStorePlatform.instance = old;
      SharedPreferences.resetStatic();
    }
  });
}
