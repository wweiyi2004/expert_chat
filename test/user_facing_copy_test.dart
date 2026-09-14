import 'dart:convert';

import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart'
    show AppDatabase, GenerationRecord;
import 'package:expert_chat/data/generation_repository.dart';
import 'package:expert_chat/data/library_file_store.dart';
import 'package:expert_chat/data/library_models.dart';
import 'package:expert_chat/data/library_repository.dart';
import 'package:expert_chat/data/task_budget_prefs.dart';
import 'package:expert_chat/domain/study/structured_output.dart';
import 'package:expert_chat/features/library/generation_history_page.dart';
import 'package:expert_chat/features/memory/memory_page.dart';
import 'package:expert_chat/features/projects/projects_page.dart';
import 'package:expert_chat/features/settings/backup_page.dart';
import 'package:expert_chat/features/settings/widgets/task_budget_editor.dart';
import 'package:expert_chat/features/study/study_generation_error.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/memory_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _Library extends LibraryRepository {
  _Library(AppDatabase db)
    : super(db, LibraryFileStore(rootOverride: 'unused-copy-test-library'));

  @override
  Future<LibraryItem?> getById(String id) async => id != 'reference-file'
      ? null
      : LibraryItem(
          id: id,
          name: '参考风景.png',
          kind: LibraryItemKind.image,
          mimeType: 'image/png',
          sizeBytes: 68,
          relativePath: 'unused.png',
          sha256: 'stored-hash',
          createdAt: DateTime(2026),
          lastUsedAt: DateTime(2026),
        );

  @override
  Future<Uint8List?> readBytes(LibraryItem item) async => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1cAAAAASUVORK5CYII=',
  );
}

class _Generations extends GenerationRepository {
  _Generations(super.db, super.library, this.records);
  final List<GenerationRecord> records;
  @override
  Future<List<GenerationRecord>> list({String? libraryItemId}) async => records;
}

class _Memory extends MemoryController {
  @override
  Future<MemoryState> build() async =>
      const MemoryState(locationLabel: 'private-storage/memory.md');
}

GenerationRecord _record({
  String id = 'internal-generation-uuid',
  String? parentId,
  String references = '[]',
}) => GenerationRecord(
  id: id,
  originalPrompt: '山间日落',
  optimizedPrompt: '山间日落',
  model: 'image-model',
  providerHost: 'https://example.com',
  imageSize: '1024x1024',
  referencesJson: references,
  parentGenerationId: parentId,
  createdAt: DateTime(2026, 9, 5),
);

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  List<GenerationRecord> records = const [],
  double width = 360,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final db = AppDatabase(NativeDatabase.memory());
  final library = _Library(db);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      libraryRepositoryProvider.overrideWithValue(library),
      generationRepositoryProvider.overrideWithValue(
        _Generations(db, library, records),
      ),
      conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
      settingsControllerProvider.overrideWith(FakeSettings.new),
      memoryControllerProvider.overrideWith(_Memory.new),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await db.close();
  });
  await container.read(chatControllerProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'project introduction is concise and document limits remain available',
    (tester) async {
      await _pumpPage(tester, const ProjectsPage());
      expect(find.text('集中管理项目会话、说明和资料。'), findsOneWidget);
      expect(find.textContaining('向量库'), findsNothing);
      await tester.tap(find.byTooltip('新建项目'));
      await tester.pumpAndSettle();
      expect(find.text('项目说明'), findsOneWidget);
      expect(find.textContaining('发送给模型'), findsOneWidget);
      expect(find.text('选择素材库文档（最多 20 份）'), findsOneWidget);
      expect(find.textContaining('32000'), findsNothing);
      await tester.ensureVisible(find.text('资料使用说明'));
      await tester.tap(find.text('资料使用说明'));
      await tester.pumpAndSettle();
      expect(find.textContaining('32000'), findsOneWidget);
      expect(find.textContaining('图片请在对话中单独添加'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('backup keeps privacy warning visible and folds detailed scope', (
    tester,
  ) async {
    await _pumpPage(tester, const BackupPage());
    expect(find.textContaining('备份未加密'), findsOneWidget);
    expect(find.textContaining('128 MB'), findsOneWidget);
    expect(find.textContaining('世界书'), findsNothing);
    await tester.tap(find.text('备份范围与注意事项'));
    await tester.pumpAndSettle();
    expect(find.textContaining('世界书'), findsOneWidget);
    expect(find.textContaining('不包含单独保存的密钥'), findsOneWidget);
    expect(find.textContaining('不会自动继续'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('task budget keeps enforcement caveats in expandable help', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TaskBudgetEditor(
              value: TaskBudgetPrefs.forPreset(TaskBudgetPreset.standard),
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('旧配置'), findsNothing);
    expect(find.textContaining('服务端'), findsNothing);
    expect(find.textContaining('无法统计'), findsNothing);
    await tester.tap(find.text('限制如何计算'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法统计搜索次数'), findsOneWidget);
    expect(find.textContaining('正常回答输出不计入'), findsOneWidget);
  });

  testWidgets('memory explains model sharing and hides the storage path', (
    tester,
  ) async {
    await _pumpPage(tester, const MemoryPage());
    expect(find.textContaining('相关内容会随对话发送给所选模型'), findsOneWidget);
    expect(find.textContaining('不会自动上传'), findsNothing);
    expect(find.text('private-storage/memory.md'), findsNothing);
    await tester.tap(find.text('存储位置'));
    await tester.pumpAndSettle();
    expect(find.text('private-storage/memory.md'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'image details show named thumbnails and readable versions, not raw metadata',
    (tester) async {
      final references = jsonEncode([
        {
          'libraryItemId': 'reference-file',
          'sha256': 'stored-hash',
          'name': '参考风景.png',
        },
        {'libraryItemId': null, 'sha256': 'missing-hash', 'name': '未保存.png'},
      ]);
      final record = _record(parentId: 'parent-uuid', references: references);
      await _pumpPage(
        tester,
        const GenerationHistoryPage(),
        records: [
          record,
          _record(id: 'parent-uuid'),
        ],
      );
      expect(find.textContaining('历史图片不推测'), findsNothing);
      await tester.tap(find.text('山间日落').first);
      await tester.pumpAndSettle();
      expect(find.text('版本 2'), findsOneWidget);
      expect(find.text('基于 版本 1 生成'), findsOneWidget);
      expect(
        find.text('山间日落'),
        findsOneWidget,
        reason: 'identical prompts are not repeated',
      );
      expect(find.text('参考风景.png'), findsOneWidget);
      expect(find.text('参考图不可用'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('internal-generation-uuid'), findsNothing);
      expect(find.text(references), findsNothing);
      await tester.ensureVisible(find.text('技术详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('技术详情'));
      await tester.pumpAndSettle();
      expect(find.text('记录编号：internal-generation-uuid'), findsOneWidget);
      expect(find.text(references), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [360.0, 1100.0]) {
    testWidgets(
      'image comparison keeps readable version labels at width $width',
      (tester) async {
        await _pumpPage(
          tester,
          const GenerationHistoryPage(),
          width: width,
          records: [
            _record(parentId: 'parent-uuid'),
            _record(id: 'parent-uuid'),
          ],
        );
        await tester.tap(find.byType(Checkbox).first);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Checkbox).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('对比选中的两个版本'));
        await tester.pumpAndSettle();
        expect(find.text('版本对比'), findsOneWidget);
        expect(find.text('版本 1'), findsOneWidget);
        expect(find.text('版本 2'), findsOneWidget);
        expect(find.textContaining('internal-generation-uuid'), findsNothing);
        expect(find.textContaining('parent-uuid'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final references in ['[]', '{invalid-json', '[42]']) {
    testWidgets(
      'image references handle empty or damaged metadata: $references',
      (tester) async {
        await _pumpPage(
          tester,
          const GenerationHistoryPage(),
          records: [_record(references: references)],
        );
        await tester.tap(find.text('山间日落'));
        await tester.pumpAndSettle();
        expect(
          find.text(references == '[]' ? '未使用参考图' : '参考图记录无法读取'),
          findsOneWidget,
        );
        expect(find.text(references), findsNothing);
        await tester.ensureVisible(find.text('按原参数生成新版本'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('按原参数生成新版本'));
        await tester.pumpAndSettle();
        expect(find.textContaining('可能产生费用'), findsOneWidget);
        expect(find.textContaining('新图不会覆盖旧图'), findsOneWidget);
        expect(find.textContaining('随机种子'), findsNothing);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('study errors keep raw output collapsed and allow copying it', (
    tester,
  ) async {
    const raw = '{"unexpected_field": "preserved output"}';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStudyGenerationError(
                context,
                title: '生成失败',
                error: const StudyStructuredOutputException(
                  feature: '测验',
                  rawOutput: raw,
                ),
              ),
              child: const Text('触发错误'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('触发错误'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请重试或更换模型'), findsOneWidget);
    expect(find.text(raw), findsNothing);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.text(raw), findsOneWidget);
    await tester.tap(find.text('复制内容'));
    await tester.pump();
    expect(copied, raw);
    expect(tester.takeException(), isNull);
  });

  testWidgets('other study errors show diagnostics only on request', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStudyGenerationError(
                context,
                title: '生成失败',
                error: StateError('internal-diagnostic'),
              ),
              child: const Text('触发错误'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('触发错误'));
    await tester.pumpAndSettle();
    expect(find.textContaining('internal-diagnostic'), findsNothing);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('internal-diagnostic'), findsOneWidget);
    expect(find.text('复制详情'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
