import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/subagent_role.dart';
import 'package:expert_chat/data/task_budget_prefs.dart';
import 'package:expert_chat/features/settings/settings_page.dart';
import 'package:expert_chat/features/settings/widgets/chat_skills_editor.dart';
import 'package:expert_chat/features/settings/widgets/subagent_roles_editor.dart';
import 'package:expert_chat/features/workbench/agents/work_agent_model_pool.dart';
import 'package:expert_chat/state/conversation_model_choice.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_agents.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'widget_test.dart' show FakeSettings;

const _longRole = SubagentRole(
  id: 'layout-role',
  name: '复杂项目资料核对与完整交付验证角色',
  when: '适用于需要完整核对多份资料、检查真实执行证据并保持项目权限边界的复杂任务；应逐项说明结论，不跳过约束。',
  instructions: '只根据真实执行证据给出结论。',
);

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async =>
      (await super.build()).copyWith(subagentRoles: [_longRole]);
}

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({
    'conversationModelChoices': jsonEncode({
      'active': 'session-specific-model',
    }),
  });
  final prefs = await SharedPreferences.getInstance();
  final result = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      settingsControllerProvider.overrideWith(_Settings.new),
    ],
  );
  await result.read(settingsControllerProvider.future);
  return result;
}

ThemeData _denseTheme() => AppTheme.light().copyWith(
  listTileTheme: const ListTileThemeData(
    dense: true,
    minTileHeight: 36,
    minVerticalPadding: 0,
    contentPadding: EdgeInsets.zero,
    titleTextStyle: TextStyle(
      fontFamily: 'NotoSansSC',
      fontSize: 13,
      height: 1.3,
    ),
    subtitleTextStyle: TextStyle(
      fontFamily: 'NotoSansSC',
      fontSize: 11.5,
      height: 1.3,
    ),
  ),
  expansionTileTheme: const ExpansionTileThemeData(
    tilePadding: EdgeInsets.zero,
    childrenPadding: EdgeInsets.zero,
  ),
);

Future<void> _settingsItem(
  WidgetTester tester,
  Finder target,
  Finder scroll,
) async {
  for (var i = 0; i < 80 && target.evaluate().isEmpty; i++) {
    final box = tester.getRect(scroll);
    await tester.dragFrom(
      Offset(box.right - 4, box.center.dy),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name, double dpr) async {
  if (!const bool.fromEnvironment('RENDER_UI_FEEDBACK')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('feedback-render')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: dpr);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/ui-feedback-review/screenshots/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets(
    'settings exposes global subagent pool and limits without changing session configuration',
    (tester) async {
      final c = await _container();
      addTearDown(c.dispose);
      final beforeModels = Map.of(c.read(conversationModelChoiceProvider));
      final beforePolicies = jsonEncode(
        c.read(sessionPolicyProvider).map((k, v) => MapEntry(k, v.toJson())),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsPage(
              initialCategory: SettingsCategory.assistants,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-assistants')), findsOneWidget);
      final scroll = find
          .descendant(
            of: find.byKey(const ValueKey('settings-assistants')),
            matching: find.byType(Scrollable),
          )
          .first;
      final pool = find.byKey(const ValueKey('settings-subagent-model-pool'));
      await _settingsItem(tester, pool, scroll);
      expect(
        tester.widget<WorkAgentModelPoolSettings>(pool).conversationId,
        isNull,
      );
      expect(find.textContaining('默认跟随各主任务的模型'), findsOneWidget);
      await tester.tap(find.text('子代理可用模型'));
      await tester.pumpAndSettle();
      final selected = find.byWidgetPredicate(
        (w) => w is CheckboxListTile && w.value == true,
      );
      expect(selected, findsOneWidget);
      await tester.tap(selected);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 · 0 个模型'));
      await tester.pumpAndSettle();
      expect(c.read(workAgentModelPoolProvider), isEmpty);
      final limits = find.byKey(const ValueKey('settings-subagent-limits'));
      await _settingsItem(tester, limits, scroll);
      await tester.tap(find.text('子代理限制'));
      await tester.pumpAndSettle();
      for (final edit in [
        ('最大深度', 4),
        ('直属子任务', 5),
        ('单个工作并发', 2),
        ('子代理工具轮数', 96),
      ]) {
        final row = find
            .ancestor(of: find.text(edit.$1), matching: find.byType(Row))
            .first;
        final dropdown = find.descendant(
          of: row,
          matching: find.byType(DropdownButton<int>),
        );
        await tester.ensureVisible(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        final option = find.text('${edit.$2}').last;
        await tester.ensureVisible(option);
        await tester.pumpAndSettle();
        await tester.tap(option);
        await tester.pumpAndSettle();
      }
      final changed = c.read(workAgentLimitsProvider);
      expect(
        [
          changed.maxDepth,
          changed.maxChildren,
          changed.maxConcurrent,
          changed.maxRounds,
        ],
        [4, 5, 2, 96],
      );
      expect(c.read(conversationModelChoiceProvider), beforeModels);
      expect(
        jsonEncode(
          c.read(sessionPolicyProvider).map((k, v) => MapEntry(k, v.toJson())),
        ),
        beforePolicies,
      );
      await _settingsItem(tester, find.text('模型响应等待'), scroll);
      expect(find.textContaining('同时适用于工作主代理和子代理'), findsOneWidget);
      expect(find.text('当前会话轮次设置'), findsNothing);
      final timeout = find.byKey(const ValueKey('工作模式首次响应等待（秒）-120'));
      await tester.ensureVisible(timeout);
      await tester.pumpAndSettle();
      await tester.enterText(timeout, '240');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        c
            .read(settingsControllerProvider)
            .requireValue
            .taskBudget
            .workResponseTimeoutSeconds,
        240,
      );
      final budget = find.byType(DropdownButtonFormField<TaskBudgetPreset>);
      await tester.ensureVisible(budget);
      await tester.pumpAndSettle();
      await tester.tap(budget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('快速').last);
      await tester.pumpAndSettle();
      final saved = c.read(settingsControllerProvider).requireValue.taskBudget;
      expect(
        [
          saved.workSeconds,
          saved.maxSearches,
          saved.maxToolCalls,
          saved.workResponseTimeoutSeconds,
        ],
        [120, 1, 4, 240],
      );
      expect(c.read(conversationModelChoiceProvider), beforeModels);
      expect(
        jsonEncode(
          c.read(sessionPolicyProvider).map((k, v) => MapEntry(k, v.toJson())),
        ),
        beforePolicies,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'skill header inset preserves fallback edit toggle add and delete callbacks',
    (tester) async {
      var catalog = ChatSkillCatalog([
        const ChatSkill(
          id: 'fallback',
          name: '通用',
          when: '未匹配时使用',
          prompt: '默认',
          fallback: true,
          builtIn: true,
        ),
        const ChatSkill(
          id: 'custom',
          name: '自定义',
          when: '需要时使用',
          prompt: '原指令',
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: _denseTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, update) => ChatSkillsEditor(
                  catalog: catalog,
                  onChanged: (value) => update(() => catalog = value),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('chat-skill-enabled-fallback')),
      );
      await tester.pumpAndSettle();
      expect(catalog.skills.first.enabled, isTrue);
      expect(find.text('至少保留一个回退任务类型'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-skill-enabled-custom')));
      await tester.pumpAndSettle();
      expect(catalog.skills.last.enabled, isFalse);
      await tester.tap(find.byKey(const ValueKey('chat-skill-title-custom')));
      await tester.pumpAndSettle();
      final name = find.descendant(
        of: find.byKey(const ValueKey('chat-skill-card-custom')),
        matching: find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '名称',
        ),
      );
      await tester.ensureVisible(name);
      await tester.pumpAndSettle();
      await tester.enterText(name, '修改名称');
      await tester.pumpAndSettle();
      expect(catalog.skills.last.name, '修改名称');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('chat-skill-card-custom')),
          matching: find.byTooltip('删除'),
        ),
      );
      await tester.pumpAndSettle();
      expect(catalog.skills, hasLength(1));
      await tester.ensureVisible(find.text('添加任务类型'));
      await tester.tap(find.text('添加任务类型'));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '新增种类');
      await tester.enterText(fields.at(1), '需要此类任务时');
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(catalog.skills.last.name, '新增种类');
      expect(catalog.skills.last.when, '需要此类任务时');
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [360.0, 390.0, 670.0]) {
    for (final scale in [1.0, 1.24]) {
      final dpr = width == 670 ? 1.5 : 1.0;
      testWidgets('role and skill descriptions stay inset at $width scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width * dpr, 1000 * dpr);
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.reset);
        final c = await _container();
        addTearDown(c.dispose);
        final catalog = ChatSkillCatalog([
          const ChatSkill(
            id: 'general',
            name: '通用',
            when: '未匹配其他任务时使用',
            prompt: '直接回答',
            fallback: true,
            builtIn: true,
          ),
          const ChatSkill(
            id: 'image_prompt',
            name: '生图提示',
            when: '为文生图模型整理提示词，清楚描述主体、场景、材质、光影与构图，并保留用户要求的文字和约束。',
            prompt: '整理可直接使用的提示词。',
            builtIn: true,
          ),
        ]);
        Widget app(Widget child) => UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: _denseTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: const ValueKey('feedback-render'),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: width < 600 ? 14 : 0,
                      vertical: 16,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(app(const SubagentRolesEditor()));
        await tester.pumpAndSettle();
        final geometry = <String, dynamic>{
          'width': width,
          'scale': scale,
          'devicePixelRatio': dpr,
        };
        void checkRole(String state) {
          final description = tester.getRect(
            find.byKey(const ValueKey('role-evolution-description')),
          );
          final dropdown = tester.getRect(
            find.byKey(const ValueKey('role-router-field')),
          );
          final label = tester.getRect(find.text('角色分配模型'));
          final panel = tester.getRect(
            find.byKey(const ValueKey('role-evolution-panel')),
          );
          expect(description.bottom + 12, lessThanOrEqualTo(label.top));
          expect(panel.bottom + 16, lessThanOrEqualTo(dropdown.top));
          geometry[state] = {
            'descriptionBottom': description.bottom,
            'labelTop': label.top,
            'panelBottom': panel.bottom,
            'dropdownTop': dropdown.top,
          };
        }

        checkRole('collapsed');
        await _capture(tester, 'roles-${width.toInt()}-$scale-collapsed', dpr);
        await tester.tap(find.textContaining('待验证角色与版本'));
        await tester.pumpAndSettle();
        checkRole('expanded');
        await _capture(tester, 'roles-${width.toInt()}-$scale-expanded', dpr);
        await tester.tap(find.textContaining('待验证角色与版本'));
        await tester.pumpAndSettle();
        final roleTitle = find.byKey(
          const ValueKey('subagent-role-title-layout-role'),
        );
        await tester.ensureVisible(roleTitle);
        await tester.pumpAndSettle();
        for (final expand in [false, true]) {
          if (expand) {
            await tester.tap(roleTitle);
            await tester.pumpAndSettle();
          }
          final title = tester.getRect(roleTitle);
          final text = tester.getRect(
            find.byKey(const ValueKey('subagent-role-description-layout-role')),
          );
          expect(title.bottom + 4, lessThanOrEqualTo(text.top));
          expect(
            tester
                .widget<Text>(
                  find.byKey(
                    const ValueKey('subagent-role-description-layout-role'),
                  ),
                )
                .maxLines,
            isNull,
          );
        }
        await tester.pumpWidget(
          app(ChatSkillsEditor(catalog: catalog, onChanged: (_) {})),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('chat-skill-card-image_prompt'));
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        for (final expand in [false, true]) {
          final title = find.byKey(
            const ValueKey('chat-skill-title-image_prompt'),
          );
          if (expand) {
            await tester.tap(title);
            await tester.pumpAndSettle();
          }
          final box = tester.getRect(card),
              header = tester.getRect(title),
              description = tester.getRect(
                find.byKey(
                  const ValueKey('chat-skill-description-image_prompt'),
                ),
              ),
              toggle = tester.getRect(
                find.byKey(const ValueKey('chat-skill-enabled-image_prompt')),
              );
          expect(description.left, greaterThanOrEqualTo(box.left + 12));
          expect(description.right, lessThanOrEqualTo(box.right - 12));
          expect(header.bottom + 4, lessThanOrEqualTo(description.top));
          expect(description.bottom, lessThanOrEqualTo(box.bottom - 8));
          expect(
            (toggle.center.dy - (header.top + description.bottom) / 2).abs(),
            lessThanOrEqualTo(2),
          );
          geometry['skill-${expand ? 'expanded' : 'collapsed'}'] = {
            'cardLeft': box.left,
            'descriptionLeft': description.left,
            'titleBottom': header.bottom,
            'descriptionTop': description.top,
            'descriptionBottom': description.bottom,
            'cardBottom': box.bottom,
          };
          await _capture(
            tester,
            'skills-${width.toInt()}-$scale-${expand ? 'expanded' : 'collapsed'}',
            dpr,
          );
        }
        if (const bool.fromEnvironment('RENDER_UI_FEEDBACK')) {
          final file = File(
            'output/ui-feedback-review/geometry/layout-${width.toInt()}-$scale.json',
          );
          await tester.runAsync(() async {
            await file.parent.create(recursive: true);
            await file.writeAsString(
              const JsonEncoder.withIndent('  ').convert(geometry),
            );
          });
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
