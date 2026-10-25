import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend.dart';
import 'server.dart';

/// Lives under the GUI ProviderScope; never owns a second controller container.
class TuiBridgeHost extends StatefulWidget {
  const TuiBridgeHost({super.key, required this.child, this.enabled = false});
  final Widget child;
  final bool enabled;
  @override
  State<TuiBridgeHost> createState() => _TuiBridgeHostState();
}

class _TuiBridgeHostState extends State<TuiBridgeHost> {
  static const _channel = MethodChannel('expert_chat/tui_bridge');
  TuiBridgeServer? _server;
  Future<void>? _starting;
  bool _requested = false;
  @override
  void initState() {
    super.initState();
    _requested = widget.enabled;
    if (Platform.isWindows) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'enable') {
          _requested = true;
          await _enable();
          return true;
        }
        throw MissingPluginException();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (Platform.isWindows) {
        try {
          final options = await _channel.invokeMapMethod<String, dynamic>(
            'getLaunchOptions',
          );
          _requested = _requested || options?['enabled'] == true;
        } on MissingPluginException {
          /* Other runners have no native launch channel. */
        }
      }
      if (_requested && mounted) await _enable();
    });
  }

  Future<void> _enable() {
    if (!mounted) return Future.value();
    return _starting ??=
        (() async {
          final container = ProviderScope.containerOf(context, listen: false);
          final server = _server ??= TuiBridgeServer(
            backend: ControllerBridgeBackend(container),
            onStopped: () async {
              if (Platform.isWindows) {
                await _channel.invokeMethod<void>('disabled');
              }
            },
          );
          try {
            await server.start();
          } catch (_) {
            debugPrint(
              'TUI bridge could not start; check the private discovery directory and permissions.',
            );
          }
        })().whenComplete(() {
          _starting = null;
        });
  }

  @override
  void dispose() {
    if (Platform.isWindows) _channel.setMethodCallHandler(null);
    unawaited(_server?.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
