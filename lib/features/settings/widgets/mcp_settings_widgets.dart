import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../data/gateway_config.dart';
import '../../../core/settings_form_style.dart';
import '../../../domain/mcp/playwright_mcp_preset.dart';

class CustomMcpEditorDialog extends StatefulWidget {
  const CustomMcpEditorDialog({
    super.key,
    required this.name,
    required this.url,
    required this.token,
    this.localProcess,
    this.computerUse = false,
    this.allowForeground = false,
  });

  final String name;
  final String url;
  final String token;
  final McpProcessConfig? localProcess;
  final bool computerUse;
  final bool allowForeground;

  @override
  State<CustomMcpEditorDialog> createState() => _CustomMcpEditorDialogState();
}

class _CustomMcpEditorDialogState extends State<CustomMcpEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.name,
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.url,
  );
  late final TextEditingController _token = TextEditingController(
    text: widget.token,
  );
  bool _obscure = true;
  late bool _local = widget.localProcess != null;
  late bool _computer = widget.computerUse;
  late bool _foreground = widget.allowForeground;
  late bool _sessionScoped = widget.localProcess?.requiresSession ?? false;
  late String _preset = widget.localProcess?.preset ?? '';
  late final _command = TextEditingController(
    text: widget.localProcess?.command ?? '',
  );
  late final _arguments = TextEditingController(
    text: widget.localProcess?.arguments.join('\n') ?? '',
  );
  late final _directory = TextEditingController(
    text: widget.localProcess?.workingDirectory ?? '',
  );
  String? _validationError;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    _command.dispose();
    _arguments.dispose();
    _directory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsFormStyle(
      child: AlertDialog(
        title: Text(widget.name.isEmpty ? '添加 MCP 服务器' : '编辑 MCP 服务器'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: '名称'),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                if (!kIsWeb &&
                    (Platform.isWindows ||
                        Platform.isMacOS ||
                        Platform.isLinux)) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('本地 MCP 程序'),
                    value: _local,
                    onChanged: (v) => setState(() => _local = v),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.travel_explore),
                    label: const Text('填入 Playwright 浏览器配置'),
                    onPressed: () => setState(() {
                      final preset = PlaywrightMcpPreset.config(
                        windows: Platform.isWindows,
                      );
                      _local = true;
                      _computer = false;
                      _foreground = false;
                      _sessionScoped = true;
                      _preset = preset.preset;
                      _name.text = 'Playwright 浏览器';
                      _command.text = preset.command;
                      _arguments.text = preset.arguments.join('\n');
                      _directory.clear();
                      _validationError = null;
                    }),
                  ),
                  if (Platform.isWindows)
                    TextButton.icon(
                      icon: const Icon(Icons.desktop_windows_outlined),
                      label: const Text('填入 Cua Driver 电脑操作配置'),
                      onPressed: () => setState(() {
                        _local = true;
                        _computer = true;
                        _preset = '';
                        _sessionScoped = false;
                        _name.text = 'Windows 电脑操作';
                        _command.text =
                            '${Platform.environment['LOCALAPPDATA']}\\ExpertChat\\drivers\\cua-0.28.0\\cua-driver.exe';
                        _arguments.text = 'mcp\n--direct';
                      }),
                    ),
                ],
                if (_local) ...[
                  if (_preset == 'playwright')
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        '读取网页、点击输入、截图并检查控制台与网络。需要 Node.js 18+；Windows 使用 Edge，其他桌面使用 Chrome。首次发现会通过 npm 下载固定版本的官方服务。每个会话和子代理使用独立浏览器窗口，不共享已有登录，也不接管工作台预览。',
                      ),
                    ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _command,
                    builder: (context, value, child) =>
                        Tooltip(message: value.text, child: child!),
                    child: TextField(
                      controller: _command,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: '程序路径',
                        hintText: '选择 cua-driver.exe 等 MCP 程序',
                        suffixIcon: IconButton(
                          tooltip: '选择 MCP 程序',
                          icon: const Icon(Icons.folder_open),
                          onPressed: () async {
                            final files = await FilePicker.pickFiles();
                            if (mounted && files?.files.single.path != null) {
                              setState(
                                () => _command.text = files!.files.single.path!,
                              );
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _arguments,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '参数（每行一个）',
                      alignLabelWithHint: true,
                      helperText: '不要在这里填写密钥',
                    ),
                  ),
                  const SizedBox(height: 16),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _directory,
                    builder: (context, value, child) =>
                        Tooltip(message: value.text, child: child!),
                    child: TextField(
                      controller: _directory,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(labelText: '工作目录（可选）'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('按会话隔离连接'),
                    subtitle: const Text('每个会话和子代理分别启动，停止任务时关闭所属连接'),
                    value: _sessionScoped,
                    onChanged: _preset == 'playwright' || _computer
                        ? null
                        : (v) => setState(() => _sessionScoped = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('电脑操作（Cua Driver）'),
                    value: _computer,
                    onChanged: _preset == 'playwright'
                        ? null
                        : (v) => setState(() {
                            _computer = v;
                            if (v) _sessionScoped = false;
                          }),
                  ),
                  if (_computer)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('允许必要时切换前台'),
                      subtitle: const Text('会切换窗口并使用鼠标键盘'),
                      value: _foreground,
                      onChanged: (v) => setState(() => _foreground = v),
                    ),
                  const Text('点击“发现工具”会运行你指定的本地程序。关闭服务或停止任务会断开本地连接。'),
                ] else ...[
                  TextField(
                    controller: _url,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'https://example.com/mcp',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _token,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Bearer Token（可选）',
                      suffixIcon: IconButton(
                        tooltip: _obscure ? '显示 Token' : '隐藏 Token',
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                ],
                if (_validationError != null)
                  Text(
                    _validationError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final nextName = _name.text.trim();
              final nextUrl = _url.text.trim();
              if (nextName.isEmpty ||
                  (_local
                      ? _command.text.trim().isEmpty
                      : GatewayConfig.normalizeBaseUrl(nextUrl).isEmpty)) {
                setState(() => _validationError = '请填写名称和连接地址或程序路径');
                return;
              }
              final process = _local
                  ? McpProcessConfig(
                      command: _command.text.trim(),
                      arguments: _arguments.text
                          .split('\n')
                          .map((v) => v.trim())
                          .where((v) => v.isNotEmpty)
                          .toList(),
                      workingDirectory: _directory.text.trim(),
                      sessionScoped: _sessionScoped,
                      preset: _preset,
                    )
                  : null;
              final presetError = process == null
                  ? null
                  : PlaywrightMcpPreset.validate(process);
              if (presetError != null) {
                setState(() => _validationError = presetError);
                return;
              }
              Navigator.of(context).pop((
                name: nextName,
                url: nextUrl,
                token: _local ? '' : _token.text.trim(),
                localProcess: process,
                computerUse: _local && _computer,
                allowForeground: _local && _computer && _foreground,
              ));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

class CustomMcpServerCard extends StatelessWidget {
  const CustomMcpServerCard({
    super.key,
    required this.server,
    required this.token,
    required this.discovering,
    required this.onEnabled,
    required this.onDiscover,
    required this.onEdit,
    required this.onDelete,
  });

  final CustomMcpServer server;
  final String token;
  final bool discovering;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onDiscover;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = discovering
        ? '发现工具中…'
        : server.lastError != null
        ? '错误'
        : !server.enabled
        ? '已关闭'
        : server.toolsDiscovered
        ? (server.localProcess == null ? '已连接' : '已发现 · 按需连接')
        : '未发现';
    final statusColor = discovering
        ? scheme.primary
        : server.lastError != null
        ? scheme.error
        : server.enabled && server.toolsDiscovered
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(server.name),
              subtitle: Text(
                server.localProcess?.command ?? server.baseUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              value: server.enabled,
              onChanged: onEnabled,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  status,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: statusColor),
                ),
                if (token.isNotEmpty)
                  Text(
                    '已保存 Token',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (server.localProcess?.requiresSession == true)
                  Text('会话隔离', style: Theme.of(context).textTheme.bodySmall),
                if (server.serverVersion != null)
                  Text(
                    'v${server.serverVersion}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            if (server.lastError != null) ...[
              const SizedBox(height: 6),
              Text(
                server.lastError!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            if (server.toolsDiscovered && server.tools.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final tool in server.tools)
                    Chip(
                      avatar: const Icon(Icons.build_outlined, size: 17),
                      label: Text(tool.name),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: discovering ? null : onDiscover,
                  icon: discovering
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.hub_outlined, size: 18),
                  label: Text(discovering ? '连接中…' : '连接并获取工具'),
                ),
                IconButton(
                  tooltip: '编辑',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
