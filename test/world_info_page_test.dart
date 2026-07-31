import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/data/world_info_repository.dart';
import 'package:expert_chat/features/story/world_info_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late WorldInfoRepository repository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = WorldInfoRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  testWidgets('deleting a world info entry asks for confirmation first', (
    tester,
  ) async {
    await repository.save(
      WorldInfoEntry(title: '禁忌书库', content: '北境魔法学院的禁书目录。'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [worldInfoRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: WorldInfoPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('禁忌书库'), findsOneWidget);

    // 打开条目菜单并选择删除 → 应弹出确认对话框，而不是立即删除。
    await tester.tap(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除世界书条目？'), findsOneWidget);
    expect(find.text('禁忌书库'), findsOneWidget, reason: '确认前条目应保留');

    // 取消 → 条目保留。
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('禁忌书库'), findsOneWidget);

    // 再次删除并确认 → 条目移除。
    await tester.tap(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('禁忌书库'), findsNothing);
    expect(find.text('还没有世界书条目'), findsOneWidget);
  });
}
