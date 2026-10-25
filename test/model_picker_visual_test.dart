import 'dart:io';
import 'dart:ui' as ui;
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/chat/widgets/composer_model_picker.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsController {
  @override
  Future<SettingsState> build() async => SettingsState(
    profiles: [
      ProviderProfile(
        id: 'official-fixture',
        name: '官方订阅 · 演示来源',
        baseUrl: 'https://api.openai.com/v1',
        chatModel: 'gpt-6-sol',
        reasonerModel: 'gpt-6-sol',
        models: ['gpt-6-sol', 'gpt-6.1-sol'],
        apiFormat: LlmApiFormat.openAiResponses,
        authMode: 'none',
      ),
      ProviderProfile(
        id: 'relay-fixture',
        name: '本地网关 · 演示来源',
        baseUrl: 'http://127.0.0.1:9999/v1',
        chatModel: 'gpt-6-sol',
        reasonerModel: 'gpt-6-sol',
        models: ['gpt-6-sol', 'relay-demo-model'],
        apiFormat: LlmApiFormat.openAiResponses,
        authMode: 'none',
      ),
    ],
    activeProfileId: 'official-fixture',
    selectedModel: 'gpt-6-sol',
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: name);
  if (!const bool.fromEnvironment('RENDER_MODEL_PICKER')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('model-visual-root')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/refinement-review/model-picker/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Material _sourceMaterial(WidgetTester tester, String id) =>
    tester.widget<Material>(
      find
          .ancestor(
            of: find.byKey(ValueKey('model-source-$id')),
            matching: find.byType(Material),
          )
          .first,
    );

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final width in [390.0, 1280.0]) {
    for (final dark in [false, true]) {
      testWidgets('model picker visual $width dark=$dark', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
            settingsControllerProvider.overrideWith(_Settings.new),
          ],
        );
        addTearDown(container.dispose);
        await container.read(settingsControllerProvider.future);
        var thinking = true;
        var effort = ReasoningEffort.high;
        final mode = ValueNotifier(ThemeMode.light);
        addTearDown(mode.dispose);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('model-visual-root'),
            child: UncontrolledProviderScope(
              container: container,
              child: ValueListenableBuilder<ThemeMode>(
                valueListenable: mode,
                builder: (_, value, _) => MaterialApp(
                  theme: AppTheme.light(),
                  darkTheme: AppTheme.dark(),
                  themeMode: value,
                  home: Scaffold(
                    appBar: AppBar(title: const Text('模型与思考 · 合成验收数据')),
                    body: StatefulBuilder(
                      builder: (context, setState) => Column(
                        children: [
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              '真实模型选择控件\nGPT-6 Sol：低 / 中 / 高 / 极高 / 最大\n来源和地址均为测试夹具，不读取账号，不发送请求。',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const Spacer(),
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: ComposerModelPicker(
                              conversationId: 'synthetic',
                              enabled: true,
                              thinking: thinking,
                              effort: effort,
                              supportsEffort: true,
                              onToggleThinking: () =>
                                  setState(() => thinking = !thinking),
                              onEffortChanged: (value) =>
                                  setState(() => effort = value),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (dark) mode.value = ThemeMode.dark;
        await tester.pumpAndSettle();
        // Theme interpolation starts a second AnimatedDefaultTextStyle pass.
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('composer-model-thinking')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        final slider = tester.widget<Slider>(
          find.byKey(const ValueKey('reasoning-effort-slider')),
        );
        expect(slider.divisions, 4);
        expect(slider.value, 2);
        final toggle = find.byKey(const ValueKey('reasoning-thinking-toggle'));
        expect(toggle.hitTestable(), findsOneWidget);
        final switchFinder = find.descendant(
          of: toggle,
          matching: find.byType(Switch),
        );
        expect(switchFinder, findsOneWidget);
        final switchSize = tester.getSize(switchFinder);
        expect(switchSize.width, lessThanOrEqualTo(64));
        expect(switchSize.height, lessThanOrEqualTo(48));
        final tag = '${width.toInt()}-${dark ? 'dark' : 'light'}';
        await _capture(tester, '$tag-thinking');
        final list = find.byKey(const ValueKey('composer-model-source-list'));
        await tester.drag(list, const Offset(0, -650));
        await tester.pumpAndSettle();
        final first = find.byKey(
          const ValueKey('model-source-official-fixture'),
        );
        final second = find.byKey(const ValueKey('model-source-relay-fixture'));
        await tester.ensureVisible(first);
        await tester.pumpAndSettle();
        final firstColor = _sourceMaterial(tester, 'official-fixture').color!;
        final secondColor = _sourceMaterial(tester, 'relay-fixture').color!;
        await _capture(tester, '$tag-sources-expanded');
        expect(
          firstColor,
          isNot(secondColor),
          reason: 'sources must have distinct shallow background colors',
        );
        expect(
          find.byKey(const ValueKey('model-option-official-fixture-gpt-6-sol')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('model-option-relay-fixture-gpt-6-sol')),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(of: first, matching: find.text('官方订阅 · 演示来源')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('model-option-official-fixture-gpt-6-sol')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('model-option-relay-fixture-gpt-6-sol')),
          findsOneWidget,
        );
        expect(second, findsOneWidget);
        await _capture(tester, '$tag-source-collapsed');
      });
    }
  }
}
