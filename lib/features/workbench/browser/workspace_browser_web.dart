import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class WorkspaceBrowserPanel extends StatefulWidget {
  const WorkspaceBrowserPanel({super.key});
  @override
  State<WorkspaceBrowserPanel> createState() => _WorkspaceBrowserPanelState();
}

class _WorkspaceBrowserPanelState extends State<WorkspaceBrowserPanel> {
  final _address = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final raw = _address.text.trim();
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      setState(() => _error = '请输入 HTTP 或 HTTPS 地址');
      return;
    }
    await launchUrl(uri, webOnlyWindowName: '_blank');
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        TextField(
          controller: _address,
          decoration: const InputDecoration(hintText: '网址或本地服务地址'),
          onSubmitted: (_) => _open(),
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _open, child: const Text('在浏览器新标签页打开')),
        if (_error != null) Text(_error!),
      ],
    ),
  );
}
