import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../domain/remote/device_agent.dart';
import '../settings/widgets/text_value_dialog.dart';
import 'dart:async';

class DeviceAgentPage extends StatefulWidget {
  const DeviceAgentPage({super.key});
  @override
  State<DeviceAgentPage> createState() => _DeviceAgentPageState();
}

class _DeviceAgentPageState extends State<DeviceAgentPage> {
  final _agent = DeviceAgent();
  Map<String, dynamic> _observation = {};
  String _status = '先在 Android 系统中启用服务，再明确开启本次控制。';
  Uint8List? _screenshot;
  bool _busy = false;
  String? _pendingText;
  @override
  void dispose() {
    unawaited(_agent.releaseSession('ui').catchError((_) {}));
    super.dispose();
  }

  Future<void> _call(String method, [Map<String, dynamic>? arguments]) async {
    if (_busy && method != 'stop' && method != 'revoke') return;
    setState(() => _busy = true);
    try {
      final response = await _agent.invoke(method, arguments);
      if (!mounted) return;
      setState(() {
        if (response is Uint8List) {
          _screenshot = response;
        } else if (response is Map) {
          final observation = response['observation'] ?? response;
          _observation = Map<String, dynamic>.from(observation as Map);
        }
        _status = '$method 已返回；动作被接受不等于任务成功，请核对新界面。';
      });
    } catch (error) {
      if (mounted) setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Android 本机控制'),
      actions: [
        TextButton(onPressed: () => _call('stop'), child: const Text('立即停止')),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '仅用于你拥有或获准控制的设备。无障碍服务能读取其他应用界面并执行操作；启用后还需在此开启本次控制。Android 11+ 可通过该服务截图，受保护内容会失败。系统权限撤销后不可继续控制。',
        ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => _call('settings'),
              child: const Text('系统授权设置'),
            ),
            FilledButton(
              onPressed: _busy ? null : () => _call('arm'),
              child: const Text('开启本次控制'),
            ),
            OutlinedButton(
              onPressed: () => _call('observe'),
              child: const Text('观察界面'),
            ),
            OutlinedButton(
              onPressed: () => _call('screenshot'),
              child: const Text('截图'),
            ),
            TextButton(
              onPressed: () => _call('revoke'),
              child: const Text('撤销服务'),
            ),
          ],
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  final text = await showDialog<String>(
                    context: context,
                    builder: (_) => TextValueDialog(
                      title: '准备输入文字',
                      initialText: _pendingText ?? '',
                      label: '待输入文字',
                      description: '关闭对话框后不会发送。窗口已经改变，请重新观察目标界面，再点击目标字段旁的输入按钮。',
                      maxLength: 10000,
                    ),
                  );
                  if (!mounted || text == null) return;
                  setState(() {
                    _pendingText = text;
                    _observation = {};
                    _status = '文字已准备，尚未发送。请重新观察并选择最新目标字段。';
                  });
                },
          child: const Text('准备输入文字'),
        ),
        if (_pendingText != null) const Text('有已准备文字；重新观察后可明确输入到选定字段。'),
        SelectableText(_status),
        Wrap(
          spacing: 8,
          children: [
            for (final action in ['back', 'home'])
              TextButton(
                onPressed: () =>
                    _call(action, {'revision': _observation['revision']}),
                child: Text(action == 'back' ? '返回' : '主屏幕'),
              ),
          ],
        ),
        if (_screenshot != null)
          Image.memory(_screenshot!, height: 360, fit: BoxFit.contain),
        for (final node in (_observation['nodes'] as List? ?? []))
          Card(
            child: ListTile(
              title: Text(
                '${node['text'] ?? node['description'] ?? node['viewId'] ?? node['target']}',
              ),
              subtitle: Text('${node['target']} · ${node['bounds']}'),
              onTap: node['clickable'] == true
                  ? () => _call('tap', {
                      'target': node['target'],
                      'revision': _observation['revision'],
                    })
                  : null,
              trailing: node['editable'] == true
                  ? IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: '输入已准备的文字（需要最新观察）',
                      onPressed: _pendingText == null || _busy
                          ? null
                          : () => _call('text', {
                              'target': node['target'],
                              'revision': _observation['revision'],
                              'text': _pendingText,
                            }),
                    )
                  : node['scrollable'] == true
                  ? IconButton(
                      icon: const Icon(Icons.arrow_downward),
                      onPressed: () => _call('scroll', {
                        'target': node['target'],
                        'revision': _observation['revision'],
                      }),
                    )
                  : null,
            ),
          ),
        ExpansionTile(
          title: const Text('原始观察'),
          children: [
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(_observation),
            ),
          ],
        ),
      ],
    ),
  );
}
