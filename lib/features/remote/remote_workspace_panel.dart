import 'dart:convert';
import 'package:flutter/material.dart';
import 'remote_automation_panel.dart';

class RemoteWorkspacePanel extends StatefulWidget {
  const RemoteWorkspacePanel({super.key, required this.request});
  final RemoteRequest request;
  @override
  State<RemoteWorkspacePanel> createState() => _RemoteWorkspacePanelState();
}

class _RemoteWorkspacePanelState extends State<RemoteWorkspacePanel> {
  String _path = '', _git = 'status', _output = '';
  List<dynamic> _entries = [];
  Future<void> _load([String? path]) async {
    try {
      final selected = path ?? _path;
      final data =
          await widget.request(
                'files?path=${Uri.encodeQueryComponent(selected)}',
              )
              as Map;
      if (mounted) {
        setState(() {
          _path = selected;
          _entries = data['entries'] as List;
          _output = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _output = e.toString());
    }
  }

  Future<void> _readGit() async {
    try {
      final data = await widget.request('git?view=$_git') as Map;
      if (mounted) {
        setState(
          () => _output =
              'exit ${data['exitCode']}\n${data['stdout']}\n${data['stderr']}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _output = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('电脑文件与 Git'),
    onExpansionChanged: (open) {
      if (open) _load();
    },
    children: [
      ListTile(
        title: Text(_path.isEmpty ? '工作目录' : _path),
        leading: IconButton(
          icon: const Icon(Icons.arrow_upward),
          onPressed: _path.isEmpty
              ? null
              : () => _load(
                  _path.split('/').take(_path.split('/').length - 1).join('/'),
                ),
        ),
        trailing: IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
      ),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final entry in _entries)
              ListTile(
                dense: true,
                leading: Icon(
                  entry['directory'] == true
                      ? Icons.folder_outlined
                      : Icons.description_outlined,
                ),
                title: Text(entry['name'] as String),
                subtitle: entry['link'] == true
                    ? const Text('符号链接不在此处展开')
                    : null,
                onTap: entry['link'] == true
                    ? null
                    : () async {
                        final path = [
                          _path,
                          entry['name'],
                        ].where((e) => e.toString().isNotEmpty).join('/');
                        if (entry['directory'] == true) {
                          await _load(path);
                          return;
                        }
                        if ((entry['size'] as int) > 512000) {
                          setState(
                            () => _output = '文件超过文本预览上限；请让 Agent 登记最终成果后流式下载。',
                          );
                          return;
                        }
                        try {
                          final data =
                              await widget.request(
                                    'artifact?path=${Uri.encodeQueryComponent(path)}',
                                  )
                                  as Map;
                          final bytes = base64Decode(data['bytes'] as String);
                          final text = utf8.decode(
                            bytes,
                            allowMalformed: false,
                          );
                          if (mounted) {
                            setState(
                              () => _output = text.contains('\u0000')
                                  ? '二进制文件，请登记成果下载。'
                                  : text,
                            );
                          }
                        } catch (e) {
                          if (mounted) setState(() => _output = '无法预览：$e');
                        }
                      },
              ),
          ],
        ),
      ),
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _git,
              items: const [
                DropdownMenuItem(value: 'status', child: Text('Git 状态')),
                DropdownMenuItem(value: 'diff', child: Text('未暂存差异')),
                DropdownMenuItem(value: 'log', child: Text('提交与父提交图')),
                DropdownMenuItem(value: 'branches', child: Text('分支')),
                DropdownMenuItem(value: 'worktrees', child: Text('Worktree')),
              ],
              onChanged: (value) => setState(() => _git = value!),
            ),
          ),
          TextButton(onPressed: _readGit, child: const Text('查询')),
        ],
      ),
      if (_output.isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            child: SelectableText(
              _output,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
    ],
  );
}
