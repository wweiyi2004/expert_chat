import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/library_models.dart';
import 'package:expert_chat/data/library_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:expert_chat/features/chat/widgets/attachment_picker.dart';
import 'package:expert_chat/features/projects/project_document_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show InMemoryLibraryFileStore;

class _Picker extends FilePickerPlatform {
  Future<FilePickerResult?> Function() respond = () async => null;
  List<String>? extensions;
  bool multiple = false;
  int calls = 0;
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
  }) {
    calls++;
    extensions = allowedExtensions;
    multiple = allowMultiple;
    return respond();
  }
}

class _Library extends LibraryRepository {
  _Library(super.db, super.files);
  bool fail = false;
  @override
  Future<List<LibraryItem>> list({LibraryItemKind? kind}) async {
    if (fail) throw StateError('offline');
    return super.list(kind: kind);
  }
}

class _Parser extends FileParser {
  @override
  Future<Attachment> parseAsync({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) async =>
      parse(name: name, mimeType: mimeType, sizeBytes: sizeBytes, bytes: bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _Library library;
  late _Picker picker;
  late LibraryItem document;
  late LibraryItem picture;
  AttachmentPickerResult? result;
  bool current = true;
  const render = bool.fromEnvironment('EXPERT_CHAT_RENDER_PICKER');

  setUpAll(() async {
    if (render && Platform.isWindows) {
      final loader = FontLoader('PickerFont')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
            ),
          ),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    library = _Library(db, InMemoryLibraryFileStore());
    document = await library.importBytes(
      name: '项目计划.txt',
      mimeType: 'text/plain',
      bytes: utf8.encode('项目计划正文'),
    );
    picture = await library.importBytes(
      name: '参考图片.png',
      mimeType: 'image/png',
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ),
    );
    final previous = FilePickerPlatform.instance;
    await db.customStatement(
      'UPDATE library_items SET last_used_at = ? WHERE id = ?',
      [
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
            1000,
        picture.id,
      ],
    );
    picker = _Picker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    result = null;
    current = true;
  });
  tearDown(() async => db.close());

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> setup(
    WidgetTester tester, {
    Size size = const Size(1100, 820),
    bool images = true,
    bool documents = true,
    int maxCount = 3,
    AttachmentPickerTab initialTab = AttachmentPickerTab.recent,
    double scale = 1,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(library),
          fileParserProvider.overrideWithValue(_Parser()),
        ],
        child: RepaintBoundary(
          key: const ValueKey('picker-render'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: const Color(0xff4263eb),
              fontFamily: render ? 'PickerFont' : null,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: FilledButton(
                    onPressed: () async => result = await showAttachmentPicker(
                      context,
                      repository: library,
                      maxCount: maxCount,
                      allowImages: images,
                      allowDocuments: documents,
                      initialTab: initialTab,
                      isCurrent: () => current,
                    ),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await drain(tester);
  }

  Finder item(LibraryItem item) =>
      find.byKey(ValueKey('attachment-item-${item.id}'));
  Future<void> tab(WidgetTester tester, AttachmentPickerTab tab) async {
    final finder = find.byKey(ValueKey('attachment-tab-${tab.name}'));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await drain(tester);
  }

  Future<void> browse(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('attachment-browse-local')));
    await drain(tester);
  }

  FilePickerResult local(String name) => FilePickerResult([
    PlatformFile(name: name, size: 4, bytes: Uint8List.fromList([1, 2, 3, 4])),
  ]);

  testWidgets(
    'recent order, search and categories preserve a shared selection',
    (tester) async {
      await setup(tester);
      expect(
        tester.getTopLeft(item(picture)).dy,
        lessThan(tester.getTopLeft(item(document)).dy),
      );
      await tester.tap(item(document));
      await tab(tester, AttachmentPickerTab.images);
      expect(item(document), findsNothing);
      await tester.tap(item(picture));
      await tab(tester, AttachmentPickerTab.library);
      await tester.enterText(
        find.byKey(const ValueKey('attachment-picker-search')),
        '项目',
      );
      await drain(tester);
      expect(item(picture), findsNothing);
      expect(find.text('已选 2 / 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('attachment-picker-confirm')));
      await drain(tester);
      expect(result!.sources.map((source) => source.name), [
        document.name,
        picture.name,
      ]);
      expect(result!.confirmImages, isFalse);
      expect(
        utf8.decode((await result!.sources.first.loadBytes!())!),
        '项目计划正文',
      );
    },
  );

  testWidgets(
    'cancelled native picker keeps selected items and can retry with remaining capacity',
    (tester) async {
      await setup(tester, maxCount: 2);
      await tester.tap(item(document));
      await browse(tester);
      expect(find.byType(AttachmentPicker), findsOneWidget);
      expect(find.text('已选 1 / 2'), findsOneWidget);
      expect(picker.multiple, isFalse);
      picker.respond = () async => local('补充.txt');
      await browse(tester);
      expect(result!.sources.map((source) => source.name), [
        document.name,
        '补充.txt',
      ]);
    },
  );

  testWidgets(
    'image-only mode filters documents from both library and native picker',
    (tester) async {
      await setup(tester, documents: false);
      expect(item(document), findsNothing);
      final docs = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('attachment-tab-documents')),
      );
      expect(docs.onSelected, isNull);
      await browse(tester);
      expect(picker.extensions, contains('png'));
      expect(picker.extensions, isNot(contains('txt')));
      picker.respond = () async => local('invalid.txt');
      await browse(tester);
      expect(result, isNull);
      expect(find.text('所选文件包含当前分类不支持的格式，请重新选择。'), findsOneWidget);
    },
  );

  testWidgets('models without vision cannot select library images', (
    tester,
  ) async {
    await setup(tester, images: false);
    expect(item(picture), findsNothing);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('attachment-tab-images')),
          )
          .onSelected,
      isNull,
    );
    await browse(tester);
    expect(picker.extensions, contains('txt'));
    expect(picker.extensions, isNot(contains('png')));
  });

  testWidgets(
    'selection limit is shared across categories and clear frees capacity',
    (tester) async {
      await setup(tester, maxCount: 1);
      await tester.tap(item(document));
      await tab(tester, AttachmentPickerTab.images);
      await tester.tap(item(picture));
      expect(find.text('已选 1 / 1'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('attachment-browse-local')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('清空'));
      await tester.tap(item(picture));
      await tester.tap(find.byKey(const ValueKey('attachment-picker-confirm')));
      await drain(tester);
      expect(result!.sources.single.name, picture.name);
    },
  );

  testWidgets(
    'loading failure offers retry and keeps native browsing available',
    (tester) async {
      library.fail = true;
      await setup(tester);
      expect(find.text('素材加载失败，请重试。你也可以浏览本机文件。'), findsOneWidget);
      await browse(tester);
      expect(picker.calls, 1);
      library.fail = false;
      await tester.tap(find.text('重新加载'));
      await drain(tester);
      expect(item(document), findsOneWidget);
    },
  );

  testWidgets('native errors stay in the panel and can be retried', (
    tester,
  ) async {
    await setup(tester);
    picker.respond = () async => throw StateError('failed');
    await browse(tester);
    expect(find.text('无法打开文件选择器，请重试。'), findsOneWidget);
    picker.respond = () async => local('retry.txt');
    await browse(tester);
    expect(result!.sources.single.name, 'retry.txt');
  });

  testWidgets('late native results are discarded after the origin changes', (
    tester,
  ) async {
    await setup(tester);
    final pending = Completer<FilePickerResult?>();
    picker.respond = () => pending.future;
    await browse(tester);
    current = false;
    pending.complete(local('old.txt'));
    await drain(tester);
    expect(result, isNull);
    expect(find.byType(AttachmentPicker), findsNothing);
  });

  testWidgets('dismissing while native picker is pending ignores its result', (
    tester,
  ) async {
    await setup(tester);
    final pending = Completer<FilePickerResult?>();
    picker.respond = () => pending.future;
    await browse(tester);
    await tester.tap(find.byKey(const ValueKey('attachment-picker-close')));
    await drain(tester);
    pending.complete(local('old.txt'));
    await drain(tester);
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('document preview returns to the existing selection', (
    tester,
  ) async {
    await setup(tester);
    await tester.tap(item(document));
    await tester.tap(find.byTooltip('预览 ${document.name}'));
    await drain(tester);
    expect(find.byType(ProjectDocumentPage), findsOneWidget);
    expect(find.textContaining('项目计划正文'), findsWidgets);
    await tester.pageBack();
    await drain(tester);
    expect(find.text('已选 1 / 3'), findsOneWidget);
  });

  for (final size in [
    const Size(1100, 820),
    const Size(320, 640),
    const Size(900, 420),
  ]) {
    testWidgets(
      'picker remains usable at $size',
      (tester) async {
        await setup(tester, size: size, scale: size.width == 320 ? 1.24 : 1);
        expect(
          find.byKey(const ValueKey('attachment-browse-local')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (render) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('picker-render')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'output/attachment-picker-${size.width.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
      variant: TargetPlatformVariant.only(
        size.width == 320 ? TargetPlatform.android : TargetPlatform.windows,
      ),
    );
  }

  testWidgets('phone keyboard keeps search and confirmation usable', (
    tester,
  ) async {
    await setup(tester, size: const Size(360, 760), keyboard: 260);
    await tester.tap(item(document));
    await tester.enterText(
      find.byKey(const ValueKey('attachment-picker-search')),
      '项目',
    );
    await drain(tester);
    await tester.tap(find.byKey(const ValueKey('attachment-picker-confirm')));
    await drain(tester);
    expect(result!.sources.single.name, document.name);
    expect(tester.takeException(), isNull);
  });
}
