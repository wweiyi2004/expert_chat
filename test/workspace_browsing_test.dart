import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/library_models.dart';
import 'package:expert_chat/data/library_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/project_repository.dart';
import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:expert_chat/features/chat/widgets/library_picker_sheet.dart';
import 'package:expert_chat/features/library/generation_history_page.dart';
import 'package:expert_chat/features/library/library_image_preview.dart';
import 'package:expert_chat/features/library/resources_page.dart';
import 'package:expert_chat/features/projects/projects_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'widget_test.dart' show FakeSettings, InMemoryLibraryFileStore;

class _DelayedProjects extends ProjectRepository {
  _DelayedProjects(AppDatabase db, LibraryRepository library)
    : super(db, library, FileParser());
  String? delayId;
  final gate = Completer<List<LibraryItem>>();
  @override
  Future<List<LibraryItem>> linkedFiles(String id) =>
      id == delayId ? gate.future : super.linkedFiles(id);
}

class _FailingLibrary extends LibraryRepository {
  _FailingLibrary(super.db, super.files);
  bool failFiles = false;
  @override
  Future<List<LibraryItem>> list({LibraryItemKind? kind}) {
    if (failFiles && kind == LibraryItemKind.file) {
      throw StateError('模拟素材列表读取失败');
    }
    return super.list(kind: kind);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late InMemoryLibraryFileStore files;
  late _FailingLibrary library;
  late _DelayedProjects projects;
  late ProviderContainer container;
  late String firstProject;
  late String secondProject;
  late LibraryItem firstFile;
  late LibraryItem secondFile;
  late LibraryItem image;
  List<Attachment>? picked;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    files = InMemoryLibraryFileStore();
    library = _FailingLibrary(db, files);
    projects = _DelayedProjects(db, library);
    firstFile = await library.importBytes(
      name: '方案甲.txt',
      mimeType: 'text/plain',
      bytes: utf8.encode('甲项目资料正文'),
    );
    secondFile = await library.importBytes(
      name: '方案乙.txt',
      mimeType: 'text/plain',
      bytes: utf8.encode('乙项目资料正文'),
    );
    image = await library.importBytes(
      name: '海边.png',
      mimeType: 'image/png',
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1cAAAAASUVORK5CYII=',
      ),
    );
    firstProject = await projects.save(
      name: '研究计划',
      instructions: '比较方案，记录结论。',
      fileIds: [firstFile.id],
    );
    secondProject = await projects.save(
      name: '旅行计划',
      instructions: '整理路线与预算。',
      fileIds: [secondFile.id],
    );
    final conversations = DriftConversationRepository(db);
    for (final item in [
      ('old', firstProject, 1),
      ('latest', firstProject, 3),
      ('other', secondProject, 2),
    ]) {
      await conversations.saveConversation(
        Conversation(
          id: item.$1,
          title: '会话 ${item.$1}',
          projectId: item.$2,
          updatedAt: DateTime(2026, 9, item.$3),
          messages: [ChatMessage(role: MessageRole.user, content: '保留的历史')],
        ),
      );
    }
    for (final item in [
      ('root', null, '海边', 'model-a', 1),
      ('child', 'root', '海边改稿', 'model-b', 2),
      ('other', null, '山间', 'model-a', 3),
    ]) {
      await db
          .into(db.generationRecords)
          .insert(
            GenerationRecordsCompanion.insert(
              id: item.$1,
              parentGenerationId: drift.Value(item.$2),
              libraryItemId: drift.Value(image.id),
              originalPrompt: item.$3,
              optimizedPrompt: item.$3,
              model: item.$4,
              providerHost: 'https://example.com',
              imageSize: '1024x1024',
              createdAt: DateTime(2026, 9, item.$5),
            ),
          );
    }
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        libraryFileStoreProvider.overrideWithValue(files),
        libraryRepositoryProvider.overrideWithValue(library),
        projectRepositoryProvider.overrideWithValue(projects),
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        settingsControllerProvider.overrideWith(FakeSettings.new),
      ],
    );
    await container.read(chatControllerProvider.future);
    picked = null;
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    double width = 1000,
    double scale = 1,
    bool pending = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => page),
                ),
                child: const Text('打开工作区'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开工作区'));
    if (pending) {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    } else {
      await settle(tester);
    }
  }

  testWidgets('资料入口可往返管理页，继续项目会话会回到聊天', (tester) async {
    await pump(tester, const ResourcesPage(), width: 360);
    await tester.tap(find.text('生图记录'));
    await settle(tester);
    expect(find.byType(GenerationHistoryPage), findsOneWidget);
    await tester.tap(find.text('素材'));
    await settle(tester);
    expect(find.byType(LibraryBrowser), findsOneWidget);
    expect(find.text('选用'), findsNothing);
    await tester.tap(find.text('资料集'));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('resource-set-$firstProject')),
        matching: find.text('管理'),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('project-continue')));
    await settle(tester);
    expect(find.byType(ResourcesPage), findsNothing);
    expect(find.byType(ProjectsPage), findsNothing);
    expect(
      container.read(chatControllerProvider).requireValue.current?.id,
      'latest',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('资料集卡片引用新建聊天且不修改原工作会话', (tester) async {
    container
        .read(chatControllerProvider.notifier)
        .newConversation(workMode: true, forceNew: true);
    final previous = container
        .read(chatControllerProvider)
        .requireValue
        .currentId;
    await pump(tester, const ResourcesPage(), width: 390);
    await tester.tap(find.byKey(ValueKey('resource-use-$firstProject')));
    await settle(tester);
    final state = container.read(chatControllerProvider).requireValue;
    expect(state.currentId, isNot(previous));
    expect(state.current!.projectId, firstProject);
    expect(state.current!.workMode, isFalse);
    expect(
      state.conversations.firstWhere((c) => c.id == previous).workMode,
      isTrue,
    );
    expect(find.byType(ResourcesPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('资料集网格新建复用原编辑器并更新真实资料集', (tester) async {
    await pump(tester, const ResourcesPage(), width: 390);
    await tester.tap(find.text('＋ 新建资料集'));
    await settle(tester);
    expect(find.text('新建资料集'), findsOneWidget);
    final name = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '资料集名称',
    );
    await tester.enterText(name, '新增的真实资料集');
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(
      (await projects.list()).any((project) => project.name == '新增的真实资料集'),
      isTrue,
    );
    await tester.pageBack();
    await settle(tester);
    expect(find.text('新增的真实资料集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('资料库素材网格保留真实文件名预览和跨类型选中', (tester) async {
    await pump(tester, const ResourcesPage(), width: 390);
    await tester.tap(find.text('素材'));
    await settle(tester);
    expect(find.text('海边.png'), findsOneWidget);
    await tester.tap(find.text('海边.png'));
    await settle(tester);
    expect(find.byType(LibraryImagePreview), findsOneWidget);
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.byTooltip('选择 海边.png'));
    await settle(tester);
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.text('文件'));
    await settle(tester);
    expect(find.text('方案甲.txt'), findsOneWidget);
    expect(find.text('方案乙.txt'), findsOneWidget);
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.text('方案甲.txt'));
    await settle(tester);
    expect(find.textContaining('甲项目资料正文'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('资料库生图标签保留两版选择比较和参数操作', (tester) async {
    await pump(tester, const ResourcesPage(), width: 390);
    await tester.tap(find.text('生图记录'));
    await settle(tester);
    expect(find.text('找到图片，继续创作'), findsNothing);
    expect(find.byKey(const ValueKey('generation-search')), findsOneWidget);
    expect(find.byTooltip('刷新'), findsOneWidget);
    final scroll = find
        .descendant(
          of: find.byKey(const ValueKey('generation-grid')),
          matching: find.byType(Scrollable),
        )
        .first;
    for (final id in ['root', 'child']) {
      final choice = find.byKey(ValueKey('generation-select-$id'));
      await tester.scrollUntilVisible(
        choice,
        id == 'root' ? 180 : -180,
        scrollable: scroll,
      );
      await tester.ensureVisible(choice);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await settle(tester);
    }
    final other = find.byKey(const ValueKey('generation-select-other'));
    await tester.scrollUntilVisible(other, -180, scrollable: scroll);
    await tester.ensureVisible(other);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Checkbox>(other).onChanged,
      isNull,
      reason: '最多两版的约束保留',
    );
    await tester.tap(find.text('对比选中的两个版本'));
    await settle(tester);
    expect(find.text('版本对比'), findsOneWidget);
    expect(find.text('仅显示变化参数'), findsOneWidget);
    expect(find.text('复制提示词'), findsWidgets);
    expect(find.text('按原参数生成新版本'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('素材管理支持文件预览，删除必须确认', (tester) async {
    await pump(tester, const LibraryPage(), width: 360);
    await tester.tap(find.byType(LibraryImagePreview));
    await settle(tester);
    expect(find.text('海边.png'), findsOneWidget);
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.text('文件'));
    await settle(tester);
    await tester.tap(find.text('方案甲.txt'));
    await settle(tester);
    expect(find.textContaining('甲项目资料正文'), findsWidgets);
    await tester.pageBack();
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, '方案甲.txt'),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('删除 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await library.getById(firstFile.id), isNotNull);
    await tester.tap(find.text('删除 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await settle(tester);
    expect(await library.getById(firstFile.id), isNull);
    expect(await library.getById(secondFile.id), isNotNull);
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'project cards expose linked files and continue the most recent conversation',
    (tester) async {
      await pump(tester, const ProjectsPage());
      expect(
        find.byKey(ValueKey('project-file-${firstFile.id}')),
        findsOneWidget,
      );
      expect(find.text('2 个会话 · 1 份资料'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('project-continue')));
      await settle(tester);
      expect(
        container.read(chatControllerProvider).requireValue.currentId,
        'latest',
      );
      expect(find.byType(ProjectsPage), findsNothing);
      expect(find.text('打开工作区'), findsOneWidget);
    },
  );

  testWidgets(
    'a slow prior project read cannot replace the newly selected documents',
    (tester) async {
      projects.delayId = firstProject;
      await pump(tester, const ProjectsPage(), pending: true);
      await tester.tap(find.byKey(ValueKey('project-card-$secondProject')));
      await settle(tester);
      expect(
        find.byKey(ValueKey('project-file-${secondFile.id}')),
        findsOneWidget,
      );
      projects.gate.complete([firstFile]);
      await settle(tester);
      expect(
        find.byKey(ValueKey('project-file-${secondFile.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('project-file-${firstFile.id}')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'project document preview reads the linked bytes without sending a model request',
    (tester) async {
      await pump(tester, const ProjectsPage(), width: 360);
      await tester.tap(find.text('资料 1'));
      await settle(tester);
      final document = find.byKey(ValueKey('project-file-${firstFile.id}'));
      await tester.ensureVisible(document);
      await tester.pumpAndSettle();
      await tester.tap(document);
      await settle(tester);
      expect(find.text('甲项目资料正文'), findsOneWidget);
      expect(find.text('复制文字'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'gallery keeps selected versions across search and identifies changed parameters',
    (tester) async {
      await pump(tester, const GenerationHistoryPage());
      await tester.tap(find.byKey(const ValueKey('generation-select-root')));
      await tester.enterText(
        find.byKey(const ValueKey('generation-search')),
        'model-b',
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('generation-open-root')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('generation-select-child')));
      await tester.pump();
      await tester.tap(find.text('对比选中的两个版本'));
      await settle(tester);
      expect(find.text('对比 A'), findsOneWidget);
      expect(find.text('对比 B'), findsOneWidget);
      expect(find.textContaining('变化参数：'), findsOneWidget);
      await tester.tap(find.text('仅显示变化参数'));
      await settle(tester);
      expect(find.text('模型 · 有变化'), findsNWidgets(2));
      expect(find.text('服务'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'series filter excludes unrelated records even with identical image bytes',
    (tester) async {
      await pump(tester, const GenerationHistoryPage());
      await tester.tap(find.byKey(const ValueKey('generation-family-child')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('generation-open-root')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('generation-open-other')), findsNothing);
      expect(find.text('版本 2'), findsOneWidget);
      await tester.tap(find.text('查看全部系列'));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('generation-open-other')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'image removal keeps version cards and readable parameters available',
    (tester) async {
      await files.delete(image.relativePath);
      await pump(
        tester,
        const GenerationHistoryPage(),
        width: 360,
        scale: 1.24,
      );
      expect(find.text('图片不可用'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('generation-open-child')));
      await settle(tester);
      expect(find.text('版本 2'), findsOneWidget);
      expect(find.text('复制提示词'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'searching and switching library categories preserves selected items',
    (tester) async {
      await pump(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await showLibraryPicker(
                  context,
                  repository: library,
                  maxCount: 3,
                );
              },
              child: const Text('选择素材'),
            ),
          ),
        ),
        width: 360,
      );
      await tester.tap(find.text('选择素材'));
      await settle(tester);
      final thumbnail = find.byType(LibraryImagePreview);
      expect(thumbnail, findsOneWidget);
      await tester.tap(thumbnail);
      await tester.pump();
      expect(find.text('删除 1'), findsNothing);
      expect(find.byTooltip('生图版本记录'), findsNothing);
      await tester.tap(find.text('文件'));
      await settle(tester);
      tester.view.viewInsets = FakeViewPadding(
        bottom: 280 * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        '方案甲',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('方案甲.txt'));
      await tester.pump();
      expect(find.text('已选 2 / 3'), findsOneWidget);
      expect(find.text('选用').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('选用'));
      await settle(tester);
      expect(picked!.map((a) => a.name), ['海边.png', '方案甲.txt']);
    },
  );
  testWidgets(
    'failed category load does not display the previous category and can retry',
    (tester) async {
      await pump(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showLibraryPicker(context, repository: library, maxCount: 3),
              child: const Text('选择素材'),
            ),
          ),
        ),
        width: 360,
      );
      await tester.tap(find.text('选择素材'));
      await settle(tester);
      library.failFiles = true;
      tester.view.physicalSize = const Size(360, 640);
      tester.view.viewInsets = FakeViewPadding(
        bottom: 300 * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.tap(find.text('文件'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('素材操作未完成'), findsOneWidget);
      expect(find.text('海边.png'), findsNothing);
      library.failFiles = false;
      await tester.ensureVisible(find.text('重新加载素材'));
      await tester.tap(find.text('重新加载素材'));
      await settle(tester);
      expect(find.text('方案甲.txt'), findsOneWidget);
      expect(find.text('素材操作未完成'), findsNothing);
    },
  );
}
