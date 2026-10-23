import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/desktop_providers.dart';
import '../../domain/desktop/workspace_host.dart';

class DesktopWorkspacesPage extends ConsumerStatefulWidget {
  const DesktopWorkspacesPage({super.key, this.pickDirectory});
  final Future<String?> Function()? pickDirectory;
  @override
  ConsumerState<DesktopWorkspacesPage> createState() =>
      _DesktopWorkspacesPageState();
}

class _DesktopWorkspacesPageState extends ConsumerState<DesktopWorkspacesPage> {
  List<DesktopWorkspace> _workspaces = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _expanded;
  int _revision = 0;
  DesktopWorkspaceHost get _host => ref.read(desktopWorkspaceHostProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _host.list();
      if (!mounted || revision != _revision) return;
      ref.invalidate(registeredDesktopWorkspacesProvider);
      ref.invalidate(desktopWorkspacesProvider);
      setState(() {
        _workspaces = result;
        if (!result.any((w) => w.id == _expanded)) {
          _expanded = result.firstOrNull?.id;
        }
      });
    } catch (error) {
      if (mounted && revision == _revision) setState(() => _error = '$error');
    } finally {
      if (mounted && revision == _revision) setState(() => _loading = false);
    }
  }

  Future<void> _remove(
    DesktopWorkspace workspace, [
    WorkspaceScope? scope,
  ]) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(scope == null ? '移除工作区？' : '删除目录规则？'),
        content: Text(
          scope == null
              ? '只移除“${workspace.name}”的登记，不删除源文件。已连接工具的后续访问也会被拒绝。'
              : '删除后将继承父目录权限，可能扩大访问范围。若要禁止访问，请将权限改为“拒绝访问”。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(scope == null ? '移除' : '删除规则'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (scope == null) {
        await _host.remove(workspace.id);
      } else {
        await _host.removeScope(workspace.id, scope.name);
      }
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit({
    DesktopWorkspace? workspace,
    WorkspaceScope? scope,
  }) async {
    final host = _host;
    final newId = const Uuid().v4();
    final changed = await showDialog<DesktopWorkspace>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DirectoryDialog(
        workspace: workspace,
        scope: scope,
        pickDirectory:
            widget.pickDirectory ??
            () => FilePicker.getDirectoryPath(dialogTitle: '选择工作目录'),
        save: (name, path, access) => workspace == null
            ? host.add(id: newId, name: name, path: path, access: access)
            : host.setScope(
                workspace: workspace.id,
                name: scope?.name ?? 'scope-$newId',
                path: path,
                access: access,
              ),
      ),
    );
    if (changed == null || !mounted) return;
    _expanded = changed.id;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _busy || _loading;
    return Scaffold(
      appBar: AppBar(
        title: const Text('电脑工作区'),
        actions: [
          IconButton(
            tooltip: '刷新工作区',
            onPressed: disabled ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('目录与访问权限', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text('为本机项目划定可读取、可修改和禁止访问的目录。更具体的子目录规则优先。'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: disabled ? null : () => _edit(),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('添加工作区'),
                  ),
                  const Text('本机文件权限 · 终端命令尚未开放'),
                ],
              ),
              const SizedBox(height: 16),
              if (_loading || _busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (!_loading && _workspaces.isEmpty && _error == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: [
                      Icon(Icons.folder_open_outlined, size: 56),
                      SizedBox(height: 16),
                      Text('还没有电脑工作区'),
                      SizedBox(height: 8),
                      Text(
                        '添加项目目录后，默认只读。可按需授权子目录写入。',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              for (final workspace in _workspaces)
                Card(
                  key: ValueKey('workspace-${workspace.id}'),
                  margin: const EdgeInsets.only(top: 12),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(workspace.name),
                        subtitle: Text(_displayPath(workspace.root)),
                        onTap: () => setState(
                          () => _expanded = _expanded == workspace.id
                              ? null
                              : workspace.id,
                        ),
                        trailing: Icon(
                          _expanded == workspace.id
                              ? Icons.expand_less
                              : Icons.expand_more,
                        ),
                      ),
                      if (_expanded == workspace.id) ...[
                        const Divider(height: 1),
                        for (final scope in workspace.scopes)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        scope.name == 'root'
                                            ? '工作区根目录'
                                            : _basename(scope.path),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: 4),
                                      SelectableText(_displayPath(scope.path)),
                                      const SizedBox(height: 6),
                                      Chip(
                                        label: Text(scope.access.label),
                                        avatar: Icon(switch (scope.access) {
                                          WorkspaceAccess.deny => Icons.block,
                                          WorkspaceAccess.readOnly =>
                                            Icons.visibility_outlined,
                                          WorkspaceAccess.readWrite =>
                                            Icons.edit_outlined,
                                        }, size: 16),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  key: ValueKey(
                                    'edit-${workspace.id}-${scope.name}',
                                  ),
                                  tooltip: '编辑目录权限',
                                  onPressed: disabled
                                      ? null
                                      : () => _edit(
                                          workspace: workspace,
                                          scope: scope,
                                        ),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                if (scope.name != 'root')
                                  IconButton(
                                    tooltip: '删除目录规则',
                                    onPressed: disabled
                                        ? null
                                        : () => _remove(workspace, scope),
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: disabled
                                    ? null
                                    : () => _edit(workspace: workspace),
                                icon: const Icon(Icons.add),
                                label: const Text('添加目录规则'),
                              ),
                              if (workspace.id != defaultDesktopWorkspaceId)
                                TextButton.icon(
                                  onPressed: disabled
                                      ? null
                                      : () => _remove(workspace),
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('移除工作区'),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _displayPath(String value) {
  if (value.startsWith(r'\\?\UNC\')) return r'\\' + value.substring(8);
  return value.startsWith(r'\\?\') ? value.substring(4) : value;
}

String _basename(String value) => value
    .replaceAll('\\', '/')
    .split('/')
    .where((part) => part.isNotEmpty)
    .last;

class _DirectoryDialog extends StatefulWidget {
  const _DirectoryDialog({
    this.workspace,
    this.scope,
    required this.pickDirectory,
    required this.save,
  });
  final DesktopWorkspace? workspace;
  final WorkspaceScope? scope;
  final Future<String?> Function() pickDirectory;
  final Future<DesktopWorkspace> Function(String, String, WorkspaceAccess) save;
  @override
  State<_DirectoryDialog> createState() => _DirectoryDialogState();
}

class _DirectoryDialogState extends State<_DirectoryDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController();
  late final _path = TextEditingController(text: widget.scope?.path ?? '');
  late WorkspaceAccess _access =
      widget.scope?.access ?? WorkspaceAccess.readOnly;
  bool _saving = false;
  String? _error;
  bool get _root => widget.scope?.name == 'root';

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    try {
      final chosen = await widget.pickDirectory();
      if (!mounted || chosen == null) return;
      setState(() {
        _path.text = chosen;
        if (_name.text.trim().isEmpty) _name.text = _basename(chosen);
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.save(
        _name.text.trim(),
        _path.text.trim(),
        _access,
      );
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(
        widget.workspace == null
            ? '添加工作区'
            : widget.scope == null
            ? '添加目录规则'
            : '编辑目录权限',
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.workspace == null) ...[
                  TextFormField(
                    key: const ValueKey('workspace-name'),
                    controller: _name,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: '工作区名称'),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? '请输入名称' : null,
                  ),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  key: const ValueKey('workspace-directory'),
                  controller: _path,
                  enabled: !_saving && !_root,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '目录路径'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '请选择或输入目录' : null,
                ),
                if (!_root)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _saving ? null : _choose,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('选择文件夹'),
                    ),
                  ),
                const SizedBox(height: 16),
                DropdownButtonFormField<WorkspaceAccess>(
                  key: const ValueKey('workspace-access'),
                  initialValue: _access,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '访问权限'),
                  items: [
                    for (final access in WorkspaceAccess.values)
                      DropdownMenuItem(
                        value: access,
                        child: Text(access.label),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _access = value!),
                ),
                const SizedBox(height: 12),
                Text(switch (_access) {
                  WorkspaceAccess.deny => '此目录及其子目录禁止访问；更具体的子目录规则可覆盖它。',
                  WorkspaceAccess.readOnly => '允许读取文件，不允许写入。子目录可单独授权。',
                  WorkspaceAccess.readWrite => '允许读取、创建和修改此目录中的文件。',
                }),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_saving)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('保存'),
        ),
      ],
    ),
  );
}
