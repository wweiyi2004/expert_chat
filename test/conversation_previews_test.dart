import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/state/conversation_previews.dart';
import 'package:expert_chat/data/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'sidebar excerpts persist, update independently and are removed with chats',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      final previews = container.read(conversationPreviewsProvider.notifier);
      await previews.record('a', '**已修复登录问题**，测试通过。');
      await previews.record('b', '文档已经整理完成。');
      expect(
        container.read(conversationPreviewsProvider)['a'],
        '已修复登录问题，测试通过。',
      );
      container.dispose();
      final reopened = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(reopened.dispose);
      expect(reopened.read(conversationPreviewsProvider)['b'], '文档已经整理完成。');
      await reopened.read(conversationPreviewsProvider.notifier).remove('a');
      expect(
        reopened.read(conversationPreviewsProvider).containsKey('a'),
        isFalse,
      );
      final activity = SearchActivity(
        kind: SearchActivityKind.mcp,
        query: '读取',
        status: SearchActivityStatus.done,
        roundElapsedMillis: 2209000,
      );
      expect(
        SearchActivity.fromJson(activity.toJson()).roundElapsedMillis,
        2209000,
      );
    },
  );
}
