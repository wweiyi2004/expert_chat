import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/clipboard/clipboard_media.dart';
import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/features/chat/widgets/chat_composer.dart';
import 'package:expert_chat/features/chat/widgets/image_pick_confirm_bar.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart'
    show
        FakeVisionSettings,
        FakeUnconfiguredSettings,
        FakeLlmProvider,
        InMemoryRepo,
        InMemoryLibraryFileStore;

class _Picker extends FilePickerPlatform {
  Future<FilePickerResult?> Function() respond = () async => null;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) => respond();
}

class _Parser extends FileParser {
  final gates = <String, Completer<void>>{};
  final entered = <String>[];
  @override
  Future<Attachment> parseAsync({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) async {
    entered.add(name);
    await gates[name]?.future;
    return Attachment(
      name: name,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      text: utf8.decode(bytes),
      imageBase64: base64Encode(bytes),
    );
  }
}

class _RejectChat extends ChatController {
  final entered = Completer<void>();
  final release = Completer<bool>();
  @override
  Future<bool> sendMessage(
    String text, {
    List<Attachment> attachments = const [],
    bool forceDocumentEdit = false,
  }) {
    entered.complete();
    return release.future;
  }
}

void main() {
  late _Picker picker;
  late _Parser parser;
  setUp(() {
    final original = FilePickerPlatform.instance;
    picker = _Picker();
    parser = _Parser();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
    addTearDown(debugResetClipboardMediaReader);
  });

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<ProviderContainer> setup(
    WidgetTester tester, {
    SettingsController Function() settings = FakeVisionSettings.new,
    _RejectChat? chat,
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
        libraryFileStoreProvider.overrideWithValue(InMemoryLibraryFileStore()),
        settingsControllerProvider.overrideWith(settings),
        llmProvider.overrideWithValue(FakeLlmProvider(const [])),
        fileParserProvider.overrideWithValue(parser),
        if (chat != null) chatControllerProvider.overrideWith(() => chat),
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
  FilePickerResult file(String name, {Uint8List? bytes}) {
    final data = bytes ?? Uint8List.fromList(utf8.encode(name));
    return FilePickerResult([
      PlatformFile(
        name: name,
        size: data.length,
        readStream: Stream.value(data),
      ),
    ]);
  }

  Future<void> pickDocument(WidgetTester tester, String name) async {
    picker.respond = () async => file(name);
    composer(tester).onPickDocuments();
    await drain(tester);
    await tester.tap(find.byKey(const ValueKey('attachment-browse-local')));
    await drain(tester);
  }

  testWidgets(
    'cancelled picker preserves text and has no residual attachments',
    (tester) async {
      await setup(tester);
      composer(tester).controller.text = 'draft';
      await pickDocument(tester, 'kept.txt');
      picker.respond = () async => null;
      composer(tester).onPickDocuments();
      await drain(tester);
      await tester.tap(find.byKey(const ValueKey('attachment-browse-local')));
      await drain(tester);
      await tester.tap(find.byKey(const ValueKey('attachment-picker-close')));
      await drain(tester);
      expect(composer(tester).controller.text, 'draft');
      expect(composer(tester).attachments.single.name, 'kept.txt');
      expect(composer(tester).picking, isFalse);
    },
  );

  testWidgets('picker result arriving after conversation switch is discarded', (
    tester,
  ) async {
    final c = await setup(tester);
    final gate = Completer<FilePickerResult?>();
    picker.respond = () => gate.future;
    composer(tester).onPickDocuments();
    await drain(tester);
    await tester.tap(find.byKey(const ValueKey('attachment-browse-local')));
    await tester.pump();
    c.read(chatControllerProvider.notifier).newConversation(projectId: 'next');
    await drain(tester);
    gate.complete(file('old.txt'));
    await drain(tester);
    expect(parser.entered, isEmpty);
    expect(composer(tester).attachments, isEmpty);
    expect(composer(tester).picking, isFalse);
  });

  testWidgets(
    'library selection uses the same parser and attachment import path',
    (tester) async {
      final c = await setup(tester);
      final saved = await c
          .read(libraryRepositoryProvider)
          .importBytes(
            name: 'saved.txt',
            mimeType: 'text/plain',
            bytes: utf8.encode('saved body'),
          );
      composer(tester).onPickLibrary();
      await drain(tester);
      await tester.tap(find.byKey(ValueKey('attachment-item-${saved.id}')));
      await drain(tester);
      await tester.tap(find.byKey(const ValueKey('attachment-picker-confirm')));
      await drain(tester);
      expect(parser.entered, ['saved.txt']);
      expect(composer(tester).attachments.single.text, 'saved body');
      expect(composer(tester).picking, isFalse);
    },
  );

  testWidgets('library confirmation after a conversation switch adds nothing', (
    tester,
  ) async {
    final c = await setup(tester);
    final saved = await c
        .read(libraryRepositoryProvider)
        .importBytes(
          name: 'old.txt',
          mimeType: 'text/plain',
          bytes: utf8.encode('old body'),
        );
    composer(tester).onPickLibrary();
    await drain(tester);
    await tester.tap(find.byKey(ValueKey('attachment-item-${saved.id}')));
    c.read(chatControllerProvider.notifier).newConversation(projectId: 'next');
    await drain(tester);
    await tester.tap(find.byKey(const ValueKey('attachment-picker-confirm')));
    await drain(tester);
    expect(parser.entered, isEmpty);
    expect(composer(tester).attachments, isEmpty);
    expect(composer(tester).picking, isFalse);
  });

  testWidgets(
    'old parser completion cannot clear a new import lock or attach old files',
    (tester) async {
      final c = await setup(tester);
      parser.gates['old.txt'] = Completer<void>();
      await pickDocument(tester, 'old.txt');
      expect(parser.entered, ['old.txt']);
      c
          .read(chatControllerProvider.notifier)
          .newConversation(projectId: 'next');
      await drain(tester);
      parser.gates['new.txt'] = Completer<void>();
      await pickDocument(tester, 'new.txt');
      parser.gates['old.txt']!.complete();
      await drain(tester);
      expect(composer(tester).picking, isTrue);
      expect(composer(tester).attachments, isEmpty);
      parser.gates['new.txt']!.complete();
      await drain(tester);
      expect(composer(tester).picking, isFalse);
      expect(composer(tester).attachments.single.name, 'new.txt');
    },
  );

  testWidgets(
    'delayed clipboard media is ignored after switching away and back',
    (tester) async {
      final c = await setup(tester);
      final origin = c.read(chatControllerProvider).requireValue.currentId!;
      final gate = Completer<ClipboardMedia>();
      clipboardMediaReader = () => gate.future;
      final pasting = composer(tester).onPaste();
      await tester.pump();
      c
          .read(chatControllerProvider.notifier)
          .newConversation(projectId: 'next');
      await drain(tester);
      await c.read(chatControllerProvider.notifier).selectConversation(origin);
      await drain(tester);
      gate.complete(ClipboardMedia(imageBytes: Uint8List.fromList([1, 2, 3])));
      await pasting;
      await drain(tester);
      expect(composer(tester).attachments, isEmpty);
      expect(find.byType(ImagePickConfirmBar), findsNothing);
    },
  );

  testWidgets(
    'text clipboard fallback cannot write into a different conversation',
    (tester) async {
      final c = await setup(tester);
      clipboardMediaReader = () async => const ClipboardMedia();
      final gate = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? await gate.future : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final pasting = composer(tester).onPaste();
      await drain(tester);
      c
          .read(chatControllerProvider.notifier)
          .newConversation(projectId: 'next');
      await drain(tester);
      gate.complete({'text': 'old clipboard'});
      await pasting;
      await drain(tester);
      expect(composer(tester).controller.text, isEmpty);
    },
  );

  testWidgets('sending during attachment preparation preserves the draft', (
    tester,
  ) async {
    final c = await setup(tester);
    parser.gates['pending.txt'] = Completer<void>();
    await pickDocument(tester, 'pending.txt');
    composer(tester).controller.text = 'draft';
    composer(tester).onSend();
    await drain(tester);
    expect(composer(tester).controller.text, 'draft');
    expect(
      c.read(chatControllerProvider).requireValue.current!.messages,
      isEmpty,
    );
    parser.gates['pending.txt']!.complete();
    await drain(tester);
    expect(composer(tester).attachments.single.name, 'pending.txt');
  });

  testWidgets(
    'rejected send restores both text and attachments in the same conversation',
    (tester) async {
      await setup(tester, settings: FakeUnconfiguredSettings.new);
      await pickDocument(tester, 'draft.txt');
      composer(tester).controller.text = 'keep me';
      composer(tester).onSend();
      await drain(tester);
      expect(composer(tester).controller.text, 'keep me');
      expect(composer(tester).attachments.single.name, 'draft.txt');
    },
  );

  for (final switchConversation in [false, true]) {
    testWidgets(
      'delayed rejection does not overwrite ${switchConversation ? 'another conversation' : 'new input'}',
      (tester) async {
        final chat = _RejectChat();
        final c = await setup(tester, chat: chat);
        composer(tester).controller.text = 'old input';
        composer(tester).onSend();
        await chat.entered.future;
        if (switchConversation) {
          c
              .read(chatControllerProvider.notifier)
              .newConversation(projectId: 'next');
          await drain(tester);
        } else {
          composer(tester).controller.text = 'new input';
        }
        chat.release.complete(false);
        await drain(tester);
        expect(
          composer(tester).controller.text,
          switchConversation ? '' : 'new input',
        );
      },
    );
  }

  testWidgets(
    'image confirmation cancels without attachment and can then attach a new selection',
    (tester) async {
      await setup(tester);
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      );
      Future<void> pick() async {
        picker.respond = () async => file('picked.png', bytes: png);
        composer(tester).onPickImages();
        await drain(tester);
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('attachment-browse-local')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await drain(tester);
      }

      await pick();
      expect(composer(tester).attachments, isEmpty);
      tester
          .widget<ImagePickConfirmBar>(find.byType(ImagePickConfirmBar))
          .onCancel();
      await drain(tester);
      expect(composer(tester).attachments, isEmpty);
      expect(find.byType(ImagePickConfirmBar), findsNothing);
      await pick();
      tester
          .widget<ImagePickConfirmBar>(find.byType(ImagePickConfirmBar))
          .onConfirm();
      await drain(tester);
      expect(composer(tester).attachments.single.name, 'picked.png');
      expect(find.byType(ImagePickConfirmBar), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
