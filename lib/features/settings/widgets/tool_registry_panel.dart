import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/tool_registry_settings.dart';
import '../../../state/settings_controller.dart';

class ToolRegistryPanel extends ConsumerStatefulWidget {
  const ToolRegistryPanel({super.key});
  @override
  ConsumerState<ToolRegistryPanel> createState() => _RegistryState();
}

class _RegistryState extends ConsumerState<ToolRegistryPanel> {
  String _query = '', _diagnostic = '';
  bool _busy = false;
  CancelToken? _installation;
  @override
  void dispose() {
    _installation?.cancel('关闭安装界面');
    super.dispose();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _diagnostic = '准备安装到应用专用虚拟环境';
    });
    try {
      final token = _installation = CancelToken();
      final result = await ref
          .read(toolRegistrySettingsProvider)
          .mathematics
          .installManaged(
            cancelToken: token,
            onStage: (stage) {
              if (mounted) setState(() => _diagnostic = stage);
            },
          );
      if (result['ok'] == true && result['pythonExecutable'] is String) {
        await ref
            .read(toolRegistrySettingsProvider.notifier)
            .configure(pythonExecutable: result['pythonExecutable'] as String);
      }
      if (mounted) {
        setState(
          () =>
              _diagnostic = const JsonEncoder.withIndent('  ').convert(result),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _diagnostic = '$error');
    } finally {
      _installation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _diagnose() async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(toolRegistrySettingsProvider)
          .mathematics
          .diagnose();
      if (mounted) {
        setState(
          () =>
              _diagnostic = const JsonEncoder.withIndent('  ').convert(result),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _diagnostic = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(toolRegistrySettingsProvider);
    final servers =
        ref.watch(settingsControllerProvider).value?.gateway.customMcpServers ??
        [];
    bool matches(String value) =>
        value.toLowerCase().contains(_query.toLowerCase());
    return ExpansionTile(
      title: const Text('工具注册表与依赖诊断'),
      subtitle: const Text('按需加载 · 内置可信适配器与已配置 MCP · 使用现有权限'),
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              labelText: '查找工具或服务',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        if (matches('math_calculate SymPy 数学 精确 统计 绘图')) ...[
          SwitchListTile(
            title: const Text('数学工具 · math_calculate'),
            subtitle: const Text(
              '默认关闭；开启后在下一轮提供。调用时才启动独立 Python 进程；15 秒超时。仅解释白名单表达式，不执行任意代码。',
            ),
            value: settings.mathEnabled,
            onChanged: (value) async {
              try {
                await ref
                    .read(toolRegistrySettingsProvider.notifier)
                    .configure(mathEnabled: value);
              } catch (error) {
                if (mounted) setState(() => _diagnostic = '$error');
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextFormField(
              key: ValueKey(settings.pythonExecutable),
              initialValue: settings.pythonExecutable,
              decoration: const InputDecoration(
                labelText: 'Python 可执行文件（不含参数）',
                helperText: '电脑使用此路径；手机/Web 使用“远程电脑任务”中已配对的电脑后端',
              ),
              onFieldSubmitted: (value) async {
                try {
                  await ref
                      .read(toolRegistrySettingsProvider.notifier)
                      .configure(pythonExecutable: value);
                } catch (error) {
                  if (mounted) setState(() => _diagnostic = '$error');
                }
              },
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              if (_installation != null)
                TextButton(
                  onPressed: () => _installation?.cancel('用户停止安装'),
                  child: const Text('停止安装'),
                ),
              FilledButton(
                onPressed: _busy ? null : _install,
                child: const Text('安装 / 更新应用专用 SymPy'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _diagnose,
                child: Text(_busy ? '检查中…' : '检查 Python / SymPy'),
              ),
              TextButton(
                onPressed: () => Clipboard.setData(
                  const ClipboardData(
                    text: 'python -m pip install sympy==1.14.0',
                  ),
                ),
                child: const Text('复制安装命令'),
              ),
              TextButton(
                onPressed: () => Clipboard.setData(
                  const ClipboardData(
                    text: 'python -m pip install --upgrade sympy==1.14.0',
                  ),
                ),
                child: const Text('复制更新命令'),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '点击安装/更新只从官方 PyPI 下载固定版本到应用专用虚拟环境；不会改动全局环境，也不接受模型建议的包或参数。复制命令可自行管理外部 Python 环境。精确计算、符号运算、数值、统计、SVG 采样绘图、等式验证共用 SymPy；缺少依赖时返回不可用。',
            ),
          ),
          if (_diagnostic.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(_diagnostic),
            ),
        ],
        for (final server in servers)
          if (matches(
            '${server.name} ${server.tools.map((tool) => tool.name).join(' ')}',
          ))
            ListTile(
              title: Text(server.name),
              subtitle: Text(
                '${server.enabled ? '启用' : '关闭'} · ${server.toolsDiscovered ? '${server.tools.length} 个已发现工具' : '未发现工具'}${server.localProcess == null ? '' : ' · 本地服务按需连接'}\n${server.tools.map((tool) => tool.name).join(', ')}${server.lastError == null ? '' : '\n依赖/连接错误：${server.lastError}'}',
              ),
            ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'MCP 的发现、启用和配置在下方对应服务卡片管理；工具能力仅以实际发现结果为准。服务安装与升级遵循其官方说明。',
          ),
        ),
      ],
    );
  }
}
