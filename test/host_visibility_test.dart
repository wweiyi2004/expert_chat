import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/features/tui_bridge/backend.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';

class _Controller extends ChatController {
  Set<String> visible = {};
  @override
  Future<ChatState> build() async => ChatState(
    conversations: [
      Conversation(id: 'first'),
      Conversation(id: 'second'),
    ],
  );
  @override
  void reportHostVisibleSessions(Set<String> conversations) {
    visible = conversations;
  }
}

class _Host extends ControllerBridgeBackend implements PersistentBridgeHost {
  _Host(super.container);
  @override
  String get hostVersion => '1';
}

void main() {
  test(
    'GUI and TUI visibility is a union and disconnect only removes its own view',
    () async {
      final container = ProviderContainer(
        overrides: [chatControllerProvider.overrideWith(_Controller.new)],
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);
      final controller =
              container.read(chatControllerProvider.notifier) as _Controller,
          host = _Host(container);
      await host.selectClientSession('gui', 'first');
      await host.selectClientSession('tui', 'second');
      expect(controller.visible, {'first', 'second'});
      await host.selectClientSession('gui', 'second');
      expect(controller.visible, {'second'});
      await host.releaseClient('gui');
      expect(controller.visible, {'second'});
      await host.releaseClient('tui');
      expect(controller.visible, isEmpty);
    },
  );
}
