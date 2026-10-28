import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/state/conversation_workspace_bindings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';

void main() {
  test(
    'workspace selection is per conversation and default clears the binding',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        conversationWorkspaceBindingsProvider.notifier,
      );
      await Future.wait([
        controller.select('a', 'project-a'),
        controller.select('b', 'project-b'),
      ]);
      expect(container.read(conversationWorkspaceBindingsProvider), {
        'a': 'project-a',
        'b': 'project-b',
      });
      final reopened = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(reopened.dispose);
      expect(
        reopened.read(conversationWorkspaceBindingsProvider)['a'],
        'project-a',
      );
      await controller.select('a', null);
      expect(container.read(conversationWorkspaceBindingsProvider), {
        'b': 'project-b',
      });
    },
  );
}
