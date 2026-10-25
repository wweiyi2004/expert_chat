import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers.dart';
import '../../../data/provider_profile.dart';
import '../../../domain/llm/model_route_diagnostics.dart';

class ModelRouteDiagnosticsPanel extends ConsumerStatefulWidget {
  const ModelRouteDiagnosticsPanel({super.key, required this.profiles});
  final List<ProviderProfile> profiles;
  @override
  ConsumerState<ModelRouteDiagnosticsPanel> createState() => _State();
}

class _State extends ConsumerState<ModelRouteDiagnosticsPanel> {
  late final ModelRouteDiagnostics _diagnostics;
  @override
  void initState() {
    super.initState();
    _diagnostics = ref.read(modelRouteDiagnosticsProvider);
    _diagnostics.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _diagnostics.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final diagnostics = _diagnostics;
    final events = diagnostics.events.reversed.take(30).toList();
    return ExpansionTile(
      title: const Text('渠道健康与路由记录'),
      subtitle: const Text('本次启动的实际请求；未探测不代表健康，余额未知'),
      children: [
        if (events.isEmpty) const ListTile(title: Text('尚无请求记录')),
        for (final event in events)
          ListTile(
            dense: true,
            title: Text(
              '${event.model} · ${widget.profiles.where((p) => p.id == event.channel).firstOrNull?.name ?? event.channel}',
            ),
            subtitle: Text(
              '${event.at.toLocal().toIso8601String().substring(11, 19)} · ${event.outcome} · ${event.elapsed.inMilliseconds} ms${event.statusCode == null ? '' : ' · HTTP ${event.statusCode}'}${event.statusCode == 429
                  ? ' · 限流或配额限制（剩余额度未知）'
                  : event.statusCode == 402
                  ? ' · 服务拒绝额度（剩余额度未知）'
                  : ''}',
            ),
          ),
        TextButton(onPressed: diagnostics.clear, child: const Text('清除本机记录')),
      ],
    );
  }
}
