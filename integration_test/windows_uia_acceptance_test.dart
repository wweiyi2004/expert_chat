import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/features/settings/settings_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import '../test/widget_test.dart'
    show FakeSettings, InMemoryRepo, InMemoryLibraryFileStore;

class _Streaming extends LlmProvider {
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    for (var i = 0; i < 40; i++) {
      if (cancelToken?.isCancelled ?? false) return;
      yield ChatChunk(
        reasoningDelta: i < 10 ? '正在整理验收步骤。' : '',
        contentDelta: i == 10
            ? '\n## 验收响应\n\n'
            : i == 20
            ? '| 指标 | 结果 |\n|---|---|\n| 可读性 | 正常 |\n\n'
            : i == 30
            ? '```dart\nvoid main() {}\n```\n\n'
            : i > 10
            ? '第 $i 条：界面应保持可读取。\n\n'
            : '',
      );
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows native MSAA remains readable during streaming and navigation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          llmProvider.overrideWithValue(_Streaming()),
          libraryFileStoreProvider.overrideWithValue(
            InMemoryLibraryFileStore(),
          ),
        ],
      );
      final directory = Directory(
        const String.fromEnvironment(
          'ACCEPTANCE_REPORT_DIR',
          defaultValue: 'output/acceptance',
        ),
      );
      await directory.create(recursive: true);
      try {
        await c.read(chatControllerProvider.future);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: Column(
                children: [
                  const Text('acceptance-uia-marker'),
                  const Expanded(child: ChatPage()),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await File(
          '${directory.path}/uia-window.json',
        ).writeAsString(jsonEncode({'pid': pid}));
        final ctrl = c.read(chatControllerProvider.notifier);
        for (var round = 0; round < 10; round++) {
          ctrl.newConversation();
          ctrl.toggleDeepThink();
          final sending = ctrl.sendMessage('验收第 $round 轮');
          for (var frame = 0; frame < 50; frame++) {
            await tester.pump(const Duration(milliseconds: 40));
          }
          await sending;
          final context = tester.element(find.byType(ChatPage));
          Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
          await tester.pumpAndSettle();
          Navigator.of(tester.element(find.byType(SettingsPage))).pop();
          await tester.pumpAndSettle();
        }
        await tester.pump(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
        expect(
          binding.semanticsEnabled,
          isTrue,
          reason:
              'The native accessibility client must enable the semantics tree.',
        );
        final probe = File('${directory.path}/uia-probe-result.json');
        for (var i = 0; i < 400 && !await probe.exists(); i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(
          await probe.exists(),
          isTrue,
          reason: 'External native probe did not report',
        );
        final native = jsonDecode(await probe.readAsString()) as Map;
        expect(native['msaaMarker'], isTrue);
        expect(native['msaaSend'], isTrue);
        expect(native['msaaNodes'] as int, greaterThan(10));
        await File('${directory.path}/uia-dart-result.json').writeAsString(
          jsonEncode({
            'status': 'passed',
            'streamedTurns': 10,
            'semanticsEnabled': binding.semanticsEnabled,
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        await db.close();
      }
    },
    skip: !const bool.fromEnvironment('EXPERT_CHAT_UIA_ACCEPTANCE'),
  );
}
