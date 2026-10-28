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

class _DeviceAgentPageState extends State<DeviceAgentPage>
    with WidgetsBindingObserver {
  final _agent = DeviceAgent();
  Map<String, dynamic> _observation = {};
  Map<String, dynamic> _deviceStatus = {};
  String _status = '正在读取设备状态…';
  Uint8List? _screenshot;
  bool _busy = false;
  String? _pendingText;
  bool get _enabled => _deviceStatus['enabled'] == true;
  bool get _armed => _deviceStatus['armed'] == true;
  bool get _taskOwnsDevice =>
      _deviceStatus['owner'] != null && _deviceStatus['owner'] != 'ui';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus({bool explain = true}) async {
    try {
      final value = await _agent.invoke('status');
      if (!mounted) return;
      setState(() {
        _deviceStatus = Map<String, dynamic>.from(value as Map);
        if (!_enabled) {
          _observation = {};
        }
        if (!_enabled || !_armed) {
          _screenshot = null;
        }
        if (explain) {
          _status = !_enabled
              ? '请先在系统设置中开启 Expert Chat 无障碍服务。'
              : !_armed
              ? '服务已开启。点击“开启本次控制”后，Agent 才能操作手机。'
              : _taskOwnsDevice
              ? 'Agent 正在使用手机，可随时点击“立即停止”。'
              : '本次控制已开启。可返回工作会话提出任务，也可在这里手动查看界面。';
        }
      });
    } catch (error) {
      if (mounted) setState(() => _status = '$error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _observation = {};
      unawaited(_refreshStatus());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
        _status = switch (method) {
          'settings' => '返回应用后会自动更新授权状态。',
          'arm' => '本次控制已开启，可以返回工作会话提出任务。',
          'stop' => '已停止本次设备控制。',
          'revoke' => '已关闭无障碍服务。',
          'observe' => '界面已更新，请选择要操作的目标。',
          'screenshot' => '截图已更新。',
          _ =>
            response is Map && response['accepted'] == false
                ? '操作未完成，请刷新界面后重试。'
                : '操作已发出，下方显示最新界面。',
        };
      });
      await _refreshStatus(explain: false);
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
        TextButton(
          onPressed: _armed ? () => _call('stop') : null,
          child: const Text('立即停止'),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('开启后，Agent 可以读取和操作其他应用界面。每次控制由你开启，也可以随时停止。'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            Chip(label: Text(_enabled ? '系统服务已开启' : '系统服务未开启')),
            Chip(
              label: Text(
                _armed ? (_taskOwnsDevice ? '任务控制中' : '本次控制已开启') : '本次控制未开启',
              ),
            ),
          ],
        ),
        SelectableText(_status),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => _call('settings'),
              child: const Text('系统授权设置'),
            ),
            FilledButton(
              onPressed: _busy || !_enabled || _armed
                  ? null
                  : () => _call('arm'),
              child: const Text('开启本次控制'),
            ),
            OutlinedButton(
              onPressed: _busy || !_enabled || _taskOwnsDevice
                  ? null
                  : () => _call('observe'),
              child: const Text('观察界面'),
            ),
            OutlinedButton(
              onPressed:
                  _busy ||
                      !_armed ||
                      _taskOwnsDevice ||
                      (_deviceStatus['sdk'] as num? ?? 0) < 30
                  ? null
                  : () => _call('screenshot'),
              child: const Text('截图'),
            ),
            TextButton(
              onPressed: !_enabled ? null : () => _call('revoke'),
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
        Wrap(
          spacing: 8,
          children: [
            for (final action in ['back', 'home'])
              TextButton(
                onPressed:
                    !_armed ||
                        _taskOwnsDevice ||
                        _observation['revision'] == null
                    ? null
                    : () =>
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
              onTap:
                  node['clickable'] == true &&
                      _armed &&
                      !_taskOwnsDevice &&
                      !_busy
                  ? () => _call('tap', {
                      'target': node['target'],
                      'revision': _observation['revision'],
                    })
                  : null,
              trailing: node['editable'] == true
                  ? IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: '输入已准备的文字（需要最新观察）',
                      onPressed:
                          _pendingText == null ||
                              _busy ||
                              !_armed ||
                              _taskOwnsDevice
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
                      onPressed: !_armed || _taskOwnsDevice || _busy
                          ? null
                          : () => _call('scroll', {
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
