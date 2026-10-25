import 'dart:convert';
import 'dart:io';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/core/prototype_widgets.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/ui_prefs.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/features/workbench/workspace_workbench_page.dart';
import 'package:expert_chat/features/workbench/runtime/workspace_command_panel.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_changes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

// This suite exercises real navigation/layout, not a native browser engine.
// A configured unavailable implementation avoids rendering the SDK's verbose
// null-platform assertion as if it were an application error message.
class _NoNativeBrowserPlatform extends WebViewPlatform {
  @override
  Never createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => throw UnsupportedError('Native browser unavailable in widget tests');
}

class _StoredSettings extends FakeSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    ui: UiPrefs.fromJson(
      jsonDecode(ref.read(sharedPrefsProvider).getString('uiPrefs')!)
          as Map<String, dynamic>,
    ),
  );
}

class _Chat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'work',
    conversations: [
      Conversation(
        id: 'work',
        workMode: true,
        title: 'layout',
        messages: [
          ChatMessage(
            id: 'answer',
            role: MessageRole.assistant,
            content: List.filled(25, '工作消息保持左对齐，并按已保存宽度和左右留白在可用聊天区域展示。').join(),
          ),
        ],
      ),
    ],
  );
}

class _ReadyChanges extends WorkChanges {
  @override
  List<WorkFileChange> build() {
    ready = Future.value();
    return const [];
  }
}

Map<String, double> _rect(Rect r) => {
  'left': r.left,
  'top': r.top,
  'width': r.width,
  'height': r.height,
  'centerX': r.center.dx,
};
Future<void> _save(String name, Object data) async {
  final file = File('output/work-polish-review/geometry/$name.json');
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
}

void main() {
  setUpAll(() async {
    WebViewPlatform.instance = _NoNativeBrowserPlatform();
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final config in [
    ('full', true, 32.0),
    ('full', false, 64.0),
    ('narrow', true, 32.0),
    ('wide', true, 32.0),
  ]) {
    for (final scale in [1.0, 1.24]) {
      testWidgets(
        'stored ${config.$1} adaptive=${config.$2} preserves width with work gutters scale=$scale',
        (tester) async {
          final stored = {
            'workContentWidth': config.$1,
            'workMessageStyle': 'document',
            'adaptiveMessagePadding': config.$2,
            'messagePadding': config.$3,
            'workbenchWidth': 560.0,
          };
          SharedPreferences.setMockInitialValues({
            'uiPrefs': jsonEncode(stored),
          });
          final prefs = await SharedPreferences.getInstance();
          final db = AppDatabase(NativeDatabase.memory());
          final container = ProviderContainer(
            overrides: [
              sharedPrefsProvider.overrideWithValue(prefs),
              appDatabaseProvider.overrideWithValue(db),
              conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
              desktopWorkspaceHostProvider.overrideWithValue(
                stub.createDesktopWorkspaceHost(),
              ),
              settingsControllerProvider.overrideWith(_StoredSettings.new),
              chatControllerProvider.overrideWith(_Chat.new),
              workChangesProvider.overrideWith(_ReadyChanges.new),
            ],
          );
          addTearDown(() async {
            container.dispose();
            await db.close();
          });
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final evidence = <String, Object>{};
          tester.view.physicalSize = const Size(990, 900);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: AppTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    disableAnimations: true,
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: child!,
                ),
                home: const ChatPage(desktopShell: true),
              ),
            ),
          );
          Future<void> measure(String tag) async {
            await tester.pumpAndSettle();
            final pane = tester.getRect(
              find.byKey(const ValueKey('html-chat-header')),
            );
            final column = tester.getRect(
              find.byKey(const ValueKey('chat-reading-column')),
            );
            final text = tester.getRect(
              find.byKey(const ValueKey('assistant-response-body')),
            );
            final input = tester.getRect(
              find.byKey(const ValueKey('composer-input-box')),
            );
            final pref = ContentWidthPref.fromWire(config.$1);
            expect(
              column.width,
              closeTo(
                pane.width < pref.maxWidth ? pane.width : pref.maxWidth,
                .1,
              ),
            );
            final gutter = config.$2
                ? (column.width < 620 ? 24.0 : 32.0)
                : 64.0;
            expect(text.left - column.left, closeTo(gutter, .1));
            expect(column.right - text.right, closeTo(gutter, .1));
            expect(column.center.dx, closeTo(pane.center.dx, .1));
            expect(text.center.dx, closeTo(pane.center.dx, .1));
            expect(input.center.dx, closeTo(pane.center.dx, .1));
            final paragraphs = find.descendant(
              of: find.byKey(const ValueKey('assistant-response-body')),
              matching: find.byType(RichText),
            );
            expect(paragraphs, findsWidgets);
            expect(
              tester.renderObject<RenderParagraph>(paragraphs.first).textAlign,
              isNot(TextAlign.center),
            );
            expect(tester.takeException(), isNull);
            evidence[tag] = {
              'pane': _rect(pane),
              'reading': _rect(column),
              'text': _rect(text),
              'input': _rect(input),
              'gutter': gutter,
            };
          }

          await measure('narrow-pane');
          tester.view.physicalSize = const Size(1300, 900);
          await measure('medium-pane');
          tester.view.physicalSize = const Size(1800, 900);
          await measure('wide-pane');
          final before = tester
              .getRect(find.byKey(const ValueKey('composer-input-box')))
              .center
              .dx;
          await tester.drag(
            find.byKey(const ValueKey('workbench-resize-handle')),
            const Offset(180, 0),
          );
          await measure('after-drag-chat-wider');
          expect(
            tester
                .getRect(find.byKey(const ValueKey('composer-input-box')))
                .center
                .dx,
            greaterThan(before),
          );
          final saved =
              jsonDecode(prefs.getString('uiPrefs')!) as Map<String, dynamic>;
          expect(saved['workContentWidth'], config.$1);
          expect(saved['adaptiveMessagePadding'], config.$2);
          expect(saved['messagePadding'], config.$3);
          await tester.runAsync(
            () => _save('message-${config.$1}-${config.$2}-$scale', evidence),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  for (final width in [340.0, 400.0, 560.0]) {
    for (final scale in [1.0, 1.24]) {
      testWidgets(
        'five run entries all visible and each row centered width=$width scale=$scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final db = AppDatabase(NativeDatabase.memory());
          final container = ProviderContainer(
            overrides: [
              sharedPrefsProvider.overrideWithValue(prefs),
              appDatabaseProvider.overrideWithValue(db),
              conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
              desktopWorkspaceHostProvider.overrideWithValue(
                stub.createDesktopWorkspaceHost(),
              ),
              settingsControllerProvider.overrideWith(FakeSettings.new),
              workChangesProvider.overrideWith(_ReadyChanges.new),
            ],
          );
          addTearDown(() async {
            container.dispose();
            await db.close();
          });
          tester.view.physicalSize = const Size(1200, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: AppTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    disableAnimations: true,
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      height: 700,
                      child: const WorkspaceWorkbenchPage(
                        conversationId: 'work',
                        embedded: true,
                        initialTab: 4,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          final rows = <double, List<Rect>>{};
          final rects = <String, Object>{};
          void check() {
            final group = tester.getRect(
              find.byKey(const ValueKey('workbench-run-entries')),
            );
            rows.clear();
            for (final kind in [4, 2, 1, 7, 8]) {
              final finder = find.byKey(ValueKey('workbench-run-$kind'));
              expect(finder.hitTestable(), findsOneWidget);
              final r = tester.getRect(finder);
              expect(r.left, greaterThanOrEqualTo(group.left - .1));
              expect(r.right, lessThanOrEqualTo(group.right + .1));
              (rows[r.top] ??= []).add(r);
              rects['$kind'] = _rect(r);
            }
            for (final line in rows.values) {
              final left = line
                  .map((r) => r.left)
                  .reduce((a, b) => a < b ? a : b);
              final right = line
                  .map((r) => r.right)
                  .reduce((a, b) => a > b ? a : b);
              expect((left + right) / 2, closeTo(group.center.dx, .6));
            }
          }

          check();
          for (final kind in [2, 1, 7, 8, 4]) {
            await tester.tap(find.byKey(ValueKey('workbench-run-$kind')));
            await tester.pump(const Duration(milliseconds: 300));
            expect(
              tester
                  .widget<PrototypeChip>(
                    find.byKey(ValueKey('workbench-run-$kind')),
                  )
                  .selected,
              isTrue,
            );
            check();
            final error = tester.takeException();
            if (error != null) {
              void inspect(RenderObject node) {
                if (node is RenderFlex &&
                    node.toString().contains('OVERFLOWING')) {
                  debugPrint(node.toStringDeep());
                }
                node.visitChildren(inspect);
              }

              inspect(tester.renderObject(find.byType(WorkspaceWorkbenchPage)));
            }
            expect(
              error,
              isNull,
              reason: 'run child kind=$kind width=$width scale=$scale',
            );
          }
          await tester.tap(find.byKey(const ValueKey('workbench-run-2')));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('新建终端'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.byType(WorkspaceCommandPanel, skipOffstage: false),
            findsNWidgets(2),
          );
          await tester.tap(find.byKey(const ValueKey('workbench-run-4')));
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.byKey(const ValueKey('workbench-instance-strip')),
            findsNothing,
          );
          check();
          await tester.tap(find.byKey(const ValueKey('workbench-run-2')));
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.byType(WorkspaceCommandPanel, skipOffstage: false),
            findsNWidgets(2),
          );
          check();
          await tester.runAsync(
            () => _save('run-$width-$scale', {
              'rows': rows.length,
              'entries': rects,
            }),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
