import 'dart:async';
import 'package:flutter/material.dart';
import '../../domain/host/host_client.dart';

class HostConnectionBanner extends StatefulWidget {
  const HostConnectionBanner({super.key, required this.child});
  final Widget child;
  @override
  State<HostConnectionBanner> createState() => _HostConnectionBannerState();
}

class _HostConnectionBannerState extends State<HostConnectionBanner> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  String? _error;
  String? _operationError;
  bool _maintenance = false;
  bool _reconnecting = false;
  @override
  void initState() {
    super.initState();
    _subscription = HostClient.current?.updates.listen((event) {
      if (!mounted) return;
      final error = event['connection_error'] as String?;
      setState(() {
        if (error != null) {
          _error = error;
        } else if (event['chat'] != null) {
          _error = null;
        }
        if (event['operation_error'] case final String message) {
          _operationError = message;
        }
        if (event.containsKey('maintenance')) {
          _maintenance = event['maintenance'] == true;
        }
      });
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error == null && _operationError == null && !_maintenance) {
      return widget.child;
    }
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error != null
                          ? '$_error。任务是否继续以宿主状态为准，未自动重发操作。'
                          : _operationError ?? '正在维护共享资料，请等待完成。',
                    ),
                  ),
                  if (_error != null)
                    TextButton(
                      onPressed: _reconnecting
                          ? null
                          : () async {
                              setState(() => _reconnecting = true);
                              try {
                                await HostClient.current?.connect(
                                  startIfNeeded: true,
                                );
                                await HostClient.current?.refresh(force: true);
                              } catch (error) {
                                if (mounted) {
                                  setState(() => _error = error.toString());
                                }
                              } finally {
                                if (mounted) {
                                  setState(() => _reconnecting = false);
                                }
                              }
                            },
                      child: const Text('重连'),
                    ),
                  if (_operationError != null)
                    TextButton(
                      onPressed: () => setState(() => _operationError = null),
                      child: const Text('知道了'),
                    ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: AbsorbPointer(absorbing: _maintenance, child: widget.child),
        ),
      ],
    );
  }
}
