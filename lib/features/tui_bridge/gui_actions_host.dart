import 'package:riverpod/riverpod.dart';
import '../../state/work_changes.dart';

Future<String?> bridgeAppVersion() async =>
    const String.fromEnvironment('EXPERT_VERSION', defaultValue: '3.8.1');

/// Installed by the desktop host's client router, never by model tools.
Future<void> Function(Map<String, Object?> request)? hostGuiNavigator;

Future<void> showBridgeGui(
  ProviderContainer container, {
  required String page,
  String? sessionId,
  WorkFileChange? change,
}) async {
  final navigate = hostGuiNavigator;
  if (navigate == null) throw StateError('图形客户端未连接');
  await navigate({
    'page': page,
    'session_id': sessionId,
    'change_id': change?.id,
  });
}
