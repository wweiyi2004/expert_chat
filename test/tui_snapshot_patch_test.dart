import 'package:test/test.dart';
import 'package:expert_chat/features/tui_bridge/snapshot_patch.dart';

void main() {
  test('stream append and revised text use distinct patch operations', () {
    final before = <String, Object?>{
      'session': {'id': 'c'},
      'messages': [
        {'id': 'm', 'role': 'assistant', 'text': 'prefix', 'thinking': 'old'},
        {'id': 'removed', 'role': 'user', 'text': 'old branch'},
      ],
      'steps': [],
      'agents': [],
    };
    final after = <String, Object?>{
      'session': {'id': 'c'},
      'messages': [
        {
          'id': 'm',
          'role': 'assistant',
          'text': 'prefix suffix',
          'thinking': 'replacement',
        },
      ],
      'steps': [
        {'id': 'tool', 'status': 'done'},
      ],
      'agents': [],
    };
    final patch = bridgeSnapshotPatch(before, after, 1, 2),
        arrays = patch['arrays'] as Map;
    final messages = arrays['messages'] as Map,
        update = (messages['updates'] as List).single as Map;
    expect(update['append'], {'text': ' suffix'});
    expect(update['fields'], {'thinking': 'replacement'});
    expect(messages['remove'], ['removed']);
    expect(messages['order'], ['m']);
    expect((patch['fields'] as Map).containsKey('session'), isFalse);
  });
}
