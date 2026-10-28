import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../state/chat_controller.dart';
import '../../state/work_changes.dart';
import '../shell/shell_tab.dart';
import '../library/resources_page.dart';
import 'gui_navigation.dart';

Future<String?> bridgeAppVersion() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    return null;
  }
}

Future<void> showBridgeGui(
  ProviderContainer container, {
  required String page,
  String? sessionId,
  WorkFileChange? change,
}) async {
  if (sessionId != null) {
    await container
        .read(chatControllerProvider.notifier)
        .selectConversation(sessionId);
  }
  container.read(shellTabProvider.notifier).set(switch (page) {
    'settings' => ShellTab.settings,
    'library' || 'media' => ShellTab.resources,
    _ => ShellTab.chat,
  });
  if (page == 'media' || page == 'library') {
    container
        .read(resourceTabProvider.notifier)
        .select(page == 'media' ? 'gen' : 'sets');
  }
  await const MethodChannel(
    'expert_chat/tui_bridge',
  ).invokeMethod<void>('show');
  if (change != null) {
    container.read(tuiGuiNavigationProvider.notifier).openChange(change);
  }
}
