import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/share/shared_intake.dart';
import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/features/chat/pending_share.dart';
import 'package:expert_chat/features/chat/widgets/chat_composer.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart'
    show
        FakeLlmProvider,
        FakeSettings,
        FakeVisionSettings,
        InMemoryLibraryFileStore,
        InMemoryRepo;

class _Parser extends FileParser {
  @override
  Future<Attachment> parseAsync({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) async => Attachment(
    name: name,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    text: utf8.decode(bytes),
  );
}

void main() {
  group('SharedPayload.fromMap', () {
    test('keeps valid files, trims text and reads skip counts', () {
      final payload = SharedPayload.fromMap({
        'text': '  https://example.com  ',
        'files': [
          {'path': '/cache/a.pdf', 'name': 'a.pdf', 'size': 12},
          {'path': '', 'name': 'broken'},
          'not a map',
        ],
        'tooLarge': 1,
        'unreadable': 2,
      });
      expect(payload.text, 'https://example.com');
      expect(payload.files.single.name, 'a.pdf');
      expect(payload.files.single.size, 12);
      expect(payload.tooLarge, 1);
      expect(payload.tooMany, 0);
      expect(payload.skipped, 3);
      expect(payload.isEmpty, isFalse);
    });

    test('an all-empty payload is empty', () {
      expect(SharedPayload.fromMap(const {}).isEmpty, isTrue);
    });
  });

  group('SharedIntake channel', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      SharedIntake.stop();
    });

    test('delivers the cold-start share, then pulls on each signal', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final queue = <Map<String, Object?>?>[
        {'text': 'cold start'},
        {'text': 'warm share'},
      ];
      var takes = 0;
      messenger.setMockMethodCallHandler(SharedIntake.channel, (call) async {
        expect(call.method, 'takeShare');
        takes++;
        return queue.isEmpty ? null : queue.removeAt(0);
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SharedIntake.channel, null),
      );

      final received = <String>[];
      await SharedIntake.listen((p) => received.add(p.text));
      expect(received, ['cold start']);

      await messenger.handlePlatformMessage(
        SharedIntake.channel.name,
        SharedIntake.channel.codec.encodeMethodCall(
          const MethodCall('shareAvailable'),
        ),
        (_) {},
      );
      expect(received, ['cold start', 'warm share']);
      expect(takes, 2);
    });

    test('is a no-op off Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(await SharedIntake.take(), isNull);
    });
  });

  group('ChatPage share intake', () {
    Future<void> drain(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<ProviderContainer> setup(
      WidgetTester tester, {
      SettingsController Function() settings = FakeVisionSettings.new,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sharedPrefsProvider.overrideWithValue(prefs),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          libraryFileStoreProvider.overrideWithValue(
            InMemoryLibraryFileStore(),
          ),
          settingsControllerProvider.overrideWith(settings),
          llmProvider.overrideWithValue(FakeLlmProvider(const [])),
          fileParserProvider.overrideWithValue(_Parser()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(chatControllerProvider.future);
      await c.read(settingsControllerProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: ChatPage()),
        ),
      );
      await drain(tester);
      return c;
    }

    ChatComposer composer(WidgetTester tester) =>
        tester.widget<ChatComposer>(find.byType(ChatComposer));

    /// Mirrors AppShell._openShared: new conversation first, then the share.
    void share(ProviderContainer c, SharedPayload payload) {
      c.read(chatControllerProvider.notifier).newConversation(projectId: 'p');
      c.read(pendingSharedPayloadProvider.notifier).set(payload);
    }

    Future<String> tempFile(
      WidgetTester tester,
      String name,
      String body,
    ) async {
      final path = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('share_test');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}${Platform.pathSeparator}$name');
        await file.writeAsString(body);
        return file.path;
      });
      return path!;
    }

    testWidgets('fills a new conversation without sending or keeping the '
        'previous draft', (tester) async {
      final c = await setup(tester);
      composer(tester).controller.text = 'old draft';
      share(c, const SharedPayload(text: 'https://example.com/post'));
      await drain(tester);

      expect(composer(tester).controller.text, 'https://example.com/post');
      final state = c.read(chatControllerProvider).value!;
      expect(state.current?.activePath ?? const [], isEmpty);
      expect(state.isStreaming, isFalse);
      expect(c.read(pendingSharedPayloadProvider), isNull);
    });

    testWidgets('attaches a shared document from the cache path', (
      tester,
    ) async {
      final c = await setup(tester);
      final path = await tempFile(tester, 'notes.txt', 'hello share');
      share(
        c,
        SharedPayload(
          text: '帮我总结',
          files: [SharedFile(path: path, name: 'notes.txt', size: 11)],
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await drain(tester);
      }

      expect(composer(tester).controller.text, '帮我总结');
      final attachments = composer(tester).attachments;
      expect(attachments.single.name, 'notes.txt');
      expect(attachments.single.text, 'hello share');
    });

    testWidgets('skips images when the model cannot see them', (tester) async {
      final c = await setup(tester, settings: FakeSettings.new);
      share(
        c,
        const SharedPayload(
          files: [SharedFile(path: '/cache/photo.jpg', name: 'photo.jpg')],
          tooLarge: 1,
        ),
      );
      await drain(tester);

      expect(composer(tester).attachments, isEmpty);
      expect(find.textContaining('当前模型不支持看图'), findsOneWidget);
      expect(find.textContaining('单个最大 10 MB'), findsOneWidget);
    });
  });
}
