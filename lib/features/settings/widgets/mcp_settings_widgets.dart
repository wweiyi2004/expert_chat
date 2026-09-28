import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../data/gateway_config.dart';

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
    return AlertDialog(
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
              const SizedBox(height: 12),
              if (!kIsWeb &&
                  (Platform.isWindows ||
                      Platform.isMacOS ||
                      Platform.isLinux)) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('本地 MCP 程序'),
                  subtitle: const Text('启动本机程序，通过标准输入输出连接'),
                  value: _local,
                  onChanged: (v) => setState(() => _local = v),
                ),
                if (Platform.isWindows)
                  TextButton.icon(
                    icon: const Icon(Icons.desktop_windows_outlined),
                    label: const Text('填入 Cua Driver 电脑操作配置'),
                    onPressed: () => setState(() {
                      _local = true;
                      _computer = true;
                      _name.text = 'Windows 电脑操作';
                      _command.text =
                          '${Platform.environment['LOCALAPPDATA']}\\ExpertChat\\drivers\\cua-0.28.0\\cua-driver.exe';
                      _arguments.text = 'mcp\n--direct';
                    }),
                  ),
              ],
              if (_local) ...[
                TextField(
                  controller: _command,
                  decoration: InputDecoration(
                    labelText: '程序路径',
                    hintText: '选择 cua-driver.exe 等 MCP 程序',
                    suffixIcon: IconButton(
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
                TextField(
                  controller: _arguments,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '参数（每行一个）',
                    helperText: '直接传给程序，无需加引号；不要在这里填写密钥',
                  ),
                ),
                TextField(
                  controller: _directory,
                  decoration: const InputDecoration(labelText: '工作目录（可选）'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('电脑操作（Cua Driver）'),
                  subtitle: const Text('只在任务模式下提供桌面工具，操作后读取新状态核验'),
                  value: _computer,
                  onChanged: (v) => setState(() => _computer = v),
                ),
                if (_computer)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许必要时切换前台'),
                    subtitle: const Text('默认关闭。开启后，后台操作被拒绝时可切换窗口并使用鼠标键盘。'),
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
                    helperText: 'Streamable HTTP，例如 https://example.com/mcp',
                  ),
                ),
                const SizedBox(height: 12),
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
            Navigator.of(context).pop((
              name: nextName,
              url: nextUrl,
              token: _local ? '' : _token.text.trim(),
              localProcess: _local
                  ? McpProcessConfig(
                      command: _command.text.trim(),
                      arguments: _arguments.text
                          .split('\n')
                          .map((v) => v.trim())
                          .where((v) => v.isNotEmpty)
                          .toList(),
                      workingDirectory: _directory.text.trim(),
                    )
                  : null,
              computerUse: _local && _computer,
              allowForeground: _local && _computer && _foreground,
            ));
          },
          child: const Text('保存'),
        ),
      ],
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
