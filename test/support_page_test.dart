import 'dart:async';
import 'package:drift/native.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/errors/app_failure.dart';
import 'package:expert_chat/domain/support/diagnostic_report.dart';
import 'package:expert_chat/features/settings/support_page.dart';
import 'package:expert_chat/features/shell/startup_error_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _info = DiagnosticInfo(
  version: '3.5.0',
  build: '4107',
  platform: 'windows',
);
Future<DiagnosticInfo> _readInfo() async => _info;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'report exports only approved fields and counts require explicit opt-in',
    () {
      final private = DiagnosticReport(
        info: _info,
        counts: {'messages': 123, 'private-file.txt': 456},
      );
      expect(private.toText(), isNot(contains('123')));
      final included = DiagnosticReport(
        info: _info,
        countsRequested: true,
        counts: {'messages': 123, 'private-file.txt': 456},
      );
      expect(included.toText(), contains('消息数量：123'));
      expect(included.toText(), isNot(contains('private-file')));
      expect(included.toText(), isNot(contains('456')));
    },
  );

  test(
    'aggregate diagnostics read counts without returning archive content',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        await DriftConversationRepository(db).saveConversation(
          Conversation(
            title: 'private-title',
            messages: [
              ChatMessage(role: MessageRole.user, content: 'private-message'),
            ],
          ),
        );
        final counts = await readDiagnosticCounts(db);
        expect(counts['conversations'], 1);
        expect(counts['messages'], 1);
        final text = DiagnosticReport(
          info: _info,
          countsRequested: true,
          counts: counts,
        ).toText();
        expect(text, isNot(contains('private-title')));
        expect(text, isNot(contains('private-message')));
      } finally {
        await db.close();
      }
    },
  );

  test('technical details redact Windows, UNC and mobile storage paths', () {
    for (final raw in [
      r'C:\Users\Alice\Private Notes\diary.txt',
      r'\\private-server\share\secret.txt',
      '/storage/emulated/0/private-note.txt',
      '/Users/Alice/report.pdf',
    ]) {
      final text = redactDiagnostics('读取失败：$raw');
      expect(text, contains('[本地路径]'));
      expect(text, isNot(contains('Alice')));
      expect(text, isNot(contains('private-note')));
      expect(text, isNot(contains('private-server')));
    }
  });

  Future<void> pump(WidgetTester tester, SupportPage page) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'opening support does not read counts, copy data or open a browser',
    (tester) async {
      var counts = 0;
      var opened = 0;
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
      await pump(
        tester,
        SupportPage(
          initialError: Exception(
            '鉴权失败（401） SECRET https://private.example /Users/Alice/private.txt',
          ),
          readInfo: _readInfo,
          readCounts: () async {
            counts++;
            return {'messages': 123};
          },
          openFeedback: (_) async {
            opened++;
            return true;
          },
        ),
      );
      expect(counts, 0);
      expect(opened, 0);
      expect(copied, isNull);
      await tester.ensureVisible(find.text('复制诊断摘要'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制诊断摘要'));
      await tester.pump();
      expect(copied, contains('错误类别：authentication'));
      for (final secret in ['SECRET', 'private.example', 'Alice', '123']) {
        expect(copied, isNot(contains(secret)));
      }
    },
  );

  testWidgets('late statistics cannot reappear after the user opts out', (
    tester,
  ) async {
    final gate = Completer<Map<String, int>>();
    await pump(
      tester,
      SupportPage(readInfo: _readInfo, readCounts: () => gate.future),
    );
    await tester.tap(find.text('包含本地数据数量'));
    await tester.pump();
    await tester.tap(find.text('包含本地数据数量'));
    await tester.pumpAndSettle();
    gate.complete({'messages': 9876});
    await tester.pumpAndSettle();
    expect(find.textContaining('9876'), findsNothing);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
  });

  testWidgets(
    'database failure leaves a usable report without raw diagnostics',
    (tester) async {
      await pump(
        tester,
        SupportPage(
          readInfo: _readInfo,
          readCounts: () async => throw StateError(
            'SQLite failed /Users/private-user/database.sqlite SECRET',
          ),
        ),
      );
      await tester.tap(find.text('包含本地数据数量'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂时无法读取：storage'), findsOneWidget);
      expect(find.textContaining('private-user'), findsNothing);
      expect(find.textContaining('SECRET'), findsNothing);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '复制诊断摘要'),
      );
      expect(button.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'feedback navigation sends no report in the URL and handles launch failure',
    (tester) async {
      Uri? target;
      await pump(
        tester,
        SupportPage(
          readInfo: _readInfo,
          openFeedback: (uri) async {
            target = uri;
            return false;
          },
        ),
      );
      await tester.ensureVisible(find.text('打开反馈页面'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开反馈页面'));
      await tester.pumpAndSettle();
      expect(target!.query, isEmpty);
      expect(target!.path, endsWith('/issues/new'));
      expect(find.textContaining('无法打开浏览器'), findsOneWidget);
    },
  );
  testWidgets(
    'startup failure opens support without a database or provider scope',
    (tester) async {
      await tester.pumpWidget(
        StartupErrorApp(
          error: StateError(
            r'SQLite cannot open C:\Users\Alice\private.sqlite',
          ),
        ),
      );
      expect(find.textContaining('Alice'), findsNothing);
      await tester.tap(find.text('生成诊断摘要'));
      await tester.pumpAndSettle();
      expect(find.byType(SupportPage), findsOneWidget);
      expect(find.text('包含本地数据数量'), findsNothing);
      expect(find.textContaining('错误类别：storage'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
