import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import '../../domain/host/host_client.dart';
import '../../domain/host/wire_models.dart';
import '../../state/chat_controller.dart';
import '../../state/work_changes.dart';
import '../../state/research_terminal_controller.dart';
import '../../domain/research/research_ssh_contract.dart';
import '../tui_bridge/gui_actions_flutter.dart';

class HostGuiActions extends ConsumerStatefulWidget {
  const HostGuiActions({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<HostGuiActions> createState() => _HostGuiActionsState();
}

class _HostGuiActionsState extends ConsumerState<HostGuiActions> {
  final _handling = <String>{};
  StreamSubscription<Map<String, dynamic>>? _subscription;
  @override
  void initState() {
    super.initState();
    _subscription = HostClient.current?.updates.listen(_receive);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _receive(HostClient.current?.state ?? {});
    });
  }

  void _receive(Map<String, dynamic> state) {
    for (final action in wireRows(state['gui_actions'])) {
      final id = action['id'] as String;
      if (_handling.add(id)) unawaited(_execute(action));
    }
  }

  Future<void> _execute(Map<String, dynamic> action) async {
    Object? result;
    String? error;
    try {
      if (action['kind'] == 'authorize') {
        final options = wireMap(action['options']);
        result = await FlutterWebAuth2.authenticate(
          url: action['url'] as String,
          callbackUrlScheme: action['scheme'] as String,
          options: FlutterWebAuth2Options(
            useWebview: options['useWebview'] == true,
            timeout: options['timeout'] as int? ?? 300,
            httpsHost: options['httpsHost'] as String?,
            httpsPath: options['httpsPath'] as String?,
          ),
        );
      } else if (action['kind'] == 'sshHostKey') {
        result = await ref
            .read(researchTerminalProvider.notifier)
            .confirmHostKey(
              ResearchHostKeyInfo(
                fingerprintSha256: action['fingerprint'] as String,
                keyType: action['keyType'] as String,
              ),
              action['previous'] as String?,
            );
      } else if (action['kind'] == 'navigate') {
        await ref.read(chatControllerProvider.future);
        if (!mounted) return;
        final change = action['change_id'] == null
            ? null
            : ref
                  .read(workChangesProvider)
                  .where((c) => c.id == action['change_id'])
                  .firstOrNull;
        await showBridgeGui(
          ProviderScope.containerOf(context, listen: false),
          page: action['page'] as String? ?? 'session',
          sessionId: action['session_id'] as String?,
          change: change,
        );
        result = true;
      } else {
        throw StateError('Unknown GUI operation');
      }
    } catch (_) {
      error = '图形操作已取消或未成功完成';
    }
    try {
      await HostClient.current?.invoke('host.gui.actionResult', {
        'id': action['id'],
        'result': result,
        'error': error,
      });
    } catch (_) {
      /* Auth callbacks are never replayed automatically after disconnect. */
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
