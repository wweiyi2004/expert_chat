import 'dart:convert';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/chat/widgets/composer_model_picker.dart';
import 'package:expert_chat/state/conversation_model_choice.dart';
import 'package:expert_chat/state/model_route_groups.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _shared = 'opaque-shared-model';
const _long =
    'a-completely-readable-model-identifier-with-a-long-version-and-context-window-2026-10-25';

class _Settings extends SettingsController {
  final selections = <String>[];
  @override
  Future<SettingsState> build() async => SettingsState(
    profiles: [
      ProviderProfile(
        id: 'beta',
        name: 'Local Bridge',
        baseUrl: 'https://b.invalid/v1',
        chatModel: _shared,
        reasonerModel: _shared,
        models: const [_shared, 'beta-only'],
      ),
      ProviderProfile(
        id: 'alpha',
        name: 'Studio Alpha',
        baseUrl: 'https://a.invalid/v1',
        chatModel: _shared,
        reasonerModel: _shared,
        models: const [_shared, _long],
      ),
      ProviderProfile(
        id: 'empty',
        name: 'Empty Source',
        baseUrl: 'https://empty.invalid',
        chatModel: '',
        reasonerModel: '',
      ),
    ],
    activeProfileId: 'beta',
    apiKey: 'key-beta',
  );
  @override
  Future<void> selectProfile(String id) async {
    selections.add(id);
    state = AsyncData(
      state.requireValue.copyWith(activeProfileId: id, apiKey: 'key-$id'),
    );
  }

  @override
  Future<void> apply({
    Object? selectedModel = SettingsState.unchanged,
    ThemeMode? themeMode,
  }) async {
    state = AsyncData(
      state.requireValue.copyWith(
        selectedModel: selectedModel,
        themeMode: themeMode,
      ),
    );
  }
}

class _Fixture {
  _Fixture(this.container);
  final ProviderContainer container;
  bool thinking = false;
  ReasoningEffort effort = ReasoningEffort.low;
}

Future<_Fixture> _open(WidgetTester tester, {bool thought = false}) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    'modelServicePriorities': jsonEncode({
      _shared: ['alpha', 'beta'],
    }),
    'modelRouteGroups.v1': jsonEncode({
      'groups': [
        {
          'id': 'route',
          'name': '写作路由',
          'models': [_shared, 'beta-only'],
          'failover': false,
        },
      ],
      'autoGroup': '',
    }),
  });
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
  final fixture = _Fixture(container);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Center(
              child: SizedBox(
                width: 320,
                child: ComposerModelPicker(
                  conversationId: 'c',
                  enabled: true,
                  thinking: fixture.thinking,
                  effort: fixture.effort,
                  supportsEffort: true,
                  onToggleThinking: thought
                      ? () =>
                            setState(() => fixture.thinking = !fixture.thinking)
                      : null,
                  onEffortChanged: thought
                      ? (value) => setState(() => fixture.effort = value)
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('composer-model-thinking')));
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  testWidgets(
    'source sections collapse independently with separate tinted surfaces',
    (tester) async {
      await _open(tester);
      final alpha = find.byKey(const ValueKey('model-source-alpha'));
      await tester.ensureVisible(alpha);
      await tester.pumpAndSettle();
      final tile = tester.widget<ExpansionTile>(alpha);
      expect(tile.initiallyExpanded, true);
      final material = tester.widget<Material>(
        find.ancestor(of: alpha, matching: find.byType(Material)).first,
      );
      expect(material.color!.a, greaterThan(0));
      await tester.tap(
        find.descendant(of: alpha, matching: find.text('Studio Alpha')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('model-option-alpha-$_shared')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('model-option-beta-$_shared')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'model-only picker has no fabricated thinking state while chat picker keeps real controls',
    (tester) async {
      await _open(tester);
      expect(find.text('模型'), findsOneWidget);
      expect(find.text('模型与思考'), findsNothing);
      expect(
        find.byKey(const ValueKey('reasoning-effort-slider')),
        findsNothing,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.textContaining('思考：关闭'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await _open(tester, thought: true);
      expect(find.text('模型与思考'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reasoning-effort-slider')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'actual source groups retain duplicate models and hide empty groups',
    (tester) async {
      await _open(tester);
      expect(find.byKey(const ValueKey('model-source-alpha')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-source-beta')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-source-empty')), findsNothing);
      expect(
        find.byKey(const ValueKey('model-option-alpha-$_shared')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('model-option-beta-$_shared')),
        findsOneWidget,
      );
      expect(find.text('自动选择'), findsOneWidget);
      expect(find.text('用户路由组'), findsOneWidget);
      expect(find.textContaining('会固定该来源'), findsOneWidget);
      expect(find.text(_long), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'search supports source and model names while preserving matching headers',
    (tester) async {
      await _open(tester);
      final search = find.byKey(const ValueKey('composer-model-search'));
      await tester.enterText(search, 'bridge');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('model-source-beta')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-source-alpha')), findsNothing);
      expect(find.text('beta-only'), findsOneWidget);
      await tester.enterText(search, 'opaque-shared');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('model-source-beta')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-source-alpha')), findsOneWidget);
      expect(find.text('beta-only'), findsNothing);
      expect(find.text(_long), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'clicking shared model under beta pins beta source and credentials',
    (tester) async {
      final f = await _open(tester);
      final row = find.byKey(const ValueKey('model-option-beta-$_shared'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      final settings = f.container
          .read(settingsControllerProvider)
          .requireValue;
      expect(settings.activeProfileId, 'beta');
      expect(settings.apiKey, 'key-beta');
      expect(settings.model, _shared);
      expect(
        f.container.read(conversationModelChoiceProvider)['c'],
        modelSourceChoice('beta', _shared),
      );
      expect(
        (f.container.read(settingsControllerProvider.notifier) as _Settings)
            .selections,
        ['beta'],
      );
    },
  );
  testWidgets(
    'Auto and configured routing group retain their conversation identifiers',
    (tester) async {
      final f = await _open(tester);
      await tester.tap(find.text('Auto'));
      await tester.pumpAndSettle();
      expect(
        f.container.read(conversationModelChoiceProvider)['c'],
        autoModelChoice,
      );
      await tester.tap(find.byKey(const ValueKey('composer-model-thinking')));
      await tester.pumpAndSettle();
      final route = find.byKey(const ValueKey('model-route-route'));
      await tester.ensureVisible(route);
      await tester.pumpAndSettle();
      await tester.tap(route);
      await tester.pumpAndSettle();
      expect(
        f.container.read(conversationModelChoiceProvider)['c'],
        '${modelGroupPrefix}route',
      );
      expect(
        (f.container.read(settingsControllerProvider.notifier) as _Settings)
            .selections,
        isEmpty,
      );
    },
  );
  testWidgets(
    'grouped model sheet preserves real thinking toggle and effort callbacks',
    (tester) async {
      final f = await _open(tester, thought: true);
      final slider = find.byKey(const ValueKey('reasoning-effort-slider'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(f.thinking, true);
      expect(f.effort, ReasoningEffort.max);
      expect(
        find.byKey(const ValueKey('composer-model-search')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
