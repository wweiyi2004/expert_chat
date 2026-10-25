import 'package:expert_chat/core/app_toast.dart';
import '../workbench_split_view.dart';
import '../../../core/prototype_widgets.dart';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../domain/workbench/git/git_workspace.dart';
import '../../../domain/workbench/git/git_workspace_factory.dart';
import 'git_commit_graph.dart';

typedef WorkspaceFileTool =
    Future<String> Function(String name, Map<String, dynamic> arguments);

/// Files use the existing permission-enforcing workspace tools. Git access is
/// authorized afresh by the caller because Git cannot enforce directory scopes.
class GitWorkspacePage extends StatefulWidget {
  const GitWorkspacePage({
    super.key,
    required this.workspaceName,
    required this.rootPath,
    required this.callFileTool,
    required this.authorizeGit,
    this.embedded = false,
    this.gitAvailable = true,
    this.onOpenFile,
    this.initialView = 0,
    this.compactHeader = false,
  });
  final int initialView;
  final bool compactHeader;
  final String workspaceName;
  final String rootPath;
  final WorkspaceFileTool callFileTool;
  final GitAuthorization authorizeGit;
  final bool embedded;
  final bool gitAvailable;
  final ValueChanged<String>? onOpenFile;

  @override
  State<GitWorkspacePage> createState() => _GitWorkspacePageState();
}

class _GitWorkspacePageState extends State<GitWorkspacePage> {
  late GitWorkspaceService _git;
  late Future<GitWorkspaceSnapshot> _snapshot;
  final Map<String, List<_FileEntry>> _directories = {};
  final Set<String> _expanded = {'.'};
  final Set<String> _loading = {};
  String? _filesError;
  String? _previewPath;
  String _preview = '';
  bool _previewLoading = false;
  bool _creating = false;
  late int _view;
  int _previewEpoch = 0;
  int _directoryEpoch = 0;

  @override
  void initState() {
    super.initState();
    _view = widget.initialView.clamp(0, 3);
    _initialize();
  }

  @override
  void didUpdateWidget(covariant GitWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootPath != widget.rootPath ||
        oldWidget.gitAvailable != widget.gitAvailable) {
      _directoryEpoch++;
      _previewEpoch++;
      _directories.clear();
      _loading.clear();
      _expanded
        ..clear()
        ..add('.');
      _previewPath = null;
      _preview = '';
      _initialize();
    }
  }

  void _initialize() {
    _git = createGitWorkspaceService(
      rootPath: widget.rootPath,
      authorize: widget.authorizeGit,
    );
    _loadSnapshot();
    _loadDirectory('.');
  }

  void _loadSnapshot() {
    _snapshot = widget.gitAvailable
        ? _git.load()
        : Future.value(
            const GitWorkspaceSnapshot(
              isRepository: false,
              message: 'Git 视图目前用于本机工作区；此处可以浏览 SSH 文件。',
            ),
          );
    // The Git tab may not be mounted yet. Retain the error for its FutureBuilder.
    _snapshot.ignore();
  }

  Future<void> _loadDirectory(String path) async {
    if (_loading.contains(path)) return;
    final epoch = _directoryEpoch;
    setState(() {
      _loading.add(path);
      _filesError = null;
    });
    try {
      final value = jsonDecode(
        await widget.callFileTool('coding_list_directory', {
          'scope': 'root',
          'path': path,
        }),
      );
      final items = value is List ? value : value['entries'] as List;
      final entries =
          [
            for (final item in items)
              _FileEntry(
                item['name'] as String,
                item['kind'] as String? ??
                    (item['directory'] == true ? 'directory' : 'file'),
              ),
          ]..sort((a, b) {
            if (a.directory != b.directory) return a.directory ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
      if (!mounted || epoch != _directoryEpoch) return;
      setState(() {
        _directories[path] = entries;
        if (value is Map && value['truncated'] == true) {
          _filesError = '目录 $path 项目较多，仅显示前 1000 项。';
        }
      });
    } catch (error) {
      if (mounted && epoch == _directoryEpoch) {
        setState(() => _filesError = '$error');
      }
    } finally {
      if (mounted && epoch == _directoryEpoch) {
        setState(() => _loading.remove(path));
      }
    }
  }

  Future<void> _openFile(String path) async {
    if (widget.onOpenFile != null) {
      setState(() => _previewPath = path);
      widget.onOpenFile!(path);
      return;
    }
    final epoch = ++_previewEpoch;
    setState(() {
      _previewPath = path;
      _previewLoading = true;
      _preview = '';
    });
    try {
      final value =
          jsonDecode(
                await widget.callFileTool('coding_read_file', {
                  'scope': 'root',
                  'path': path,
                }),
              )
              as Map<String, dynamic>;
      if (mounted && epoch == _previewEpoch) {
        setState(() => _preview = value['content'] as String);
      }
    } catch (error) {
      if (mounted && epoch == _previewEpoch) {
        setState(() => _preview = '无法预览：$error');
      }
    } finally {
      if (mounted && epoch == _previewEpoch) {
        setState(() => _previewLoading = false);
      }
    }
  }

  void _refresh() {
    setState(() {
      _loadSnapshot();
      _directoryEpoch++;
      _directories.clear();
      _loading.clear();
    });
    for (final path in _expanded.toList()) {
      _loadDirectory(path);
    }
    if (widget.onOpenFile == null && _previewPath != null) {
      _openFile(_previewPath!);
    }
  }

  Future<void> _createWorktree() async {
    final git = _git;
    var input = '';
    String? validation;
    final branch = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          String target = '输入分支名后显示完整目标路径';
          try {
            target = git.worktreeTarget(input.trim());
          } catch (_) {
            /* Incomplete input. */
          }
          return AlertDialog(
            title: const Text('创建独立工作树'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: '新分支名',
                      hintText: 'task-search',
                      errorText: validation,
                    ),
                    onChanged: (value) => update(() {
                      input = value;
                      validation = null;
                    }),
                  ),
                  const SizedBox(height: 16),
                  const Text('从当前 HEAD 创建新分支，文件放在：'),
                  const SizedBox(height: 8),
                  SelectableText(target),
                  const SizedBox(height: 12),
                  const Text(
                    '创建后可将该目录添加为工作区，再启动独立任务。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  try {
                    git.worktreeTarget(input.trim());
                    Navigator.pop(context, input.trim());
                  } catch (error) {
                    update(() => validation = '$error');
                  }
                },
                child: const Text('确认创建'),
              ),
            ],
          );
        },
      ),
    );
    if (branch == null || !mounted || git != _git) return;
    setState(() => _creating = true);
    try {
      await git.createWorktree(branch);
      if (!mounted) return;
      AppToastMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已创建：${git.worktreeTarget(branch)}')),
      );
      _refresh();
    } catch (error) {
      if (mounted) {
        AppToastMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const labels = ['文件', 'Git 改动', '提交关系图', '工作树'];
    final body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              if (!widget.compactHeader || widget.initialView != 0)
                PopupMenuButton<int>(
                  tooltip: '切换文件与 Git 视图',
                  initialValue: _view,
                  onSelected: (value) => setState(() => _view = value),
                  itemBuilder: (_) => [
                    for (
                      var i = widget.compactHeader ? 1 : 0;
                      i < labels.length;
                      i++
                    )
                      PopupMenuItem(value: i, child: Text(labels[i])),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          labels[_view],
                          style: const TextStyle(fontSize: 12),
                        ),
                        const Icon(Icons.expand_more, size: 14),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: Tooltip(
                  message: widget.rootPath,
                  child: Text(
                    widget.rootPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      color: PrototypeColors.of(context).muted,
                    ),
                  ),
                ),
              ),
              PrototypeIconButton(
                tooltip: '刷新工作区',
                icon: Icons.refresh,
                onPressed: _refresh,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: IndexedStack(
            index: _view,
            children: [
              _fileBrowser(),
              _gitView(_changes),
              _gitView(_history),
              _gitView(_worktrees),
            ],
          ),
        ),
      ],
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: Text(widget.workspaceName)),
            body: body,
          );
  }

  Widget _gitView(Widget Function(GitWorkspaceSnapshot data) builder) =>
      FutureBuilder<GitWorkspaceSnapshot>(
        future: _snapshot,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _notice(
              '${snapshot.error}',
              retry: () => setState(_loadSnapshot),
            );
          }
          final data = snapshot.requireData;
          if (!data.isRepository) {
            return _notice(data.message ?? '当前目录不是 Git 仓库。');
          }
          return builder(data);
        },
      );

  Widget _notice(String text, {VoidCallback? retry}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          if (retry != null)
            TextButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    ),
  );

  Widget _fileBrowser() {
    final rows = <Widget>[];
    void add(String directory, int depth) {
      for (final entry in _directories[directory] ?? const <_FileEntry>[]) {
        final path = directory == '.' ? entry.name : '$directory/${entry.name}';
        rows.add(
          ListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -4),
            minTileHeight: MediaQuery.sizeOf(context).width < 840 ? 44 : 34,
            minLeadingWidth: 14,
            horizontalTitleGap: 8,
            titleTextStyle: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: PrototypeColors.of(context).ink,
            ),
            contentPadding: EdgeInsets.only(left: 14 + depth * 14, right: 10),
            selected: path == _previewPath,
            leading: Icon(
              entry.directory
                  ? (_expanded.contains(path)
                        ? Icons.folder_open
                        : Icons.folder_outlined)
                  : Icons.insert_drive_file_outlined,
              size: 14,
            ),
            title: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _loading.contains(path)
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            enabled: entry.kind != 'link-unavailable',
            onTap: () {
              if (entry.directory) {
                setState(() {
                  if (!_expanded.remove(path)) _expanded.add(path);
                });
                if (_expanded.contains(path) &&
                    !_directories.containsKey(path)) {
                  _loadDirectory(path);
                }
              } else {
                _openFile(path);
              }
            },
          ),
        );
        if (_expanded.contains(path)) add(path, depth + 1);
      }
    }

    add('.', 0);
    final tree = Column(
      children: [
        if (_filesError != null)
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              _filesError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_loading.contains('.')) const LinearProgressIndicator(),
        Expanded(
          child: rows.isEmpty && !_loading.contains('.')
              ? _notice('目录中没有可显示的文件。')
              : ListView(children: rows),
        ),
      ],
    );
    if (widget.onOpenFile != null) return tree;
    final preview = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_previewPath != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _previewPath!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _previewLoading
              ? const Center(child: CircularProgressIndicator())
              : _previewPath == null
              ? _notice('选择文件查看内容')
              : _SourceView(text: _preview),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        return WorkbenchSplitView(
          first: tree,
          second: preview,
          breakpoint: 600,
        );
      },
    );
  }

  Widget _changes(GitWorkspaceSnapshot data) {
    if (data.changes.isEmpty) return _notice('工作区干净，没有未提交改动。');
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('${data.branch} · ${data.changes.length} 个改动'),
        ),
        for (final change in data.changes)
          ListTile(
            leading: SizedBox(
              width: 30,
              child: Text(
                change.status,
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            title: Text(change.path),
            subtitle: Text(change.untracked ? '未跟踪' : '查看已暂存与未暂存差异'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => Dialog(
                child: SizedBox(
                  width: 1000,
                  height: 700,
                  child: Column(
                    children: [
                      ListTile(
                        title: Text(change.path),
                        trailing: IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: _GitDiffView(load: () => _git.diff(change)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _history(GitWorkspaceSnapshot data) => GitCommitGraph(
    snapshot: data,
    onSelect: (commit) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 1100),
        builder: (sheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheet).height * .82,
            child: Column(
              children: [
                ListTile(
                  title: Text(commit.subject),
                  subtitle: Text('${commit.id} · ${commit.author}'),
                  trailing: IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(sheet),
                    icon: const Icon(Icons.close),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _GitDiffView(load: () => _git.commitDiff(commit.id)),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _worktrees(GitWorkspaceSnapshot data) => ListView(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _creating || data.commits.isEmpty
                ? null
                : _createWorktree,
            icon: _creating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            label: Text(_creating ? '正在创建…' : '创建独立工作树'),
          ),
        ),
      ),
      for (final worktree in data.worktrees)
        ListTile(
          leading: const Icon(Icons.folder_copy_outlined),
          title: Text(worktree.branch),
          subtitle: SelectableText(worktree.path),
          trailing: worktree.locked
              ? const Tooltip(
                  message: '工作树已锁定',
                  child: Icon(Icons.lock_outline),
                )
              : null,
        ),
    ],
  );
}

class _FileEntry {
  const _FileEntry(this.name, this.kind);
  final String name;
  final String kind;
  bool get directory => kind == 'directory';
}

class _GitDiffView extends StatefulWidget {
  const _GitDiffView({required this.load});
  final Future<String> Function() load;
  @override
  State<_GitDiffView> createState() => _GitDiffViewState();
}

class _GitDiffViewState extends State<_GitDiffView> {
  late final Future<String> _diff = widget.load();
  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _diff,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
      return _SourceView(
        text: snapshot.data!.isEmpty ? '文件没有文本差异。' : snapshot.data!,
        diff: true,
      );
    },
  );
}

class _SourceView extends StatelessWidget {
  const _SourceView({required this.text, this.diff = false});
  final String text;
  final bool diff;
  @override
  Widget build(BuildContext context) {
    final lines = const LineSplitter().convert(text);
    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final line = lines[index];
          final color = !diff
              ? null
              : line.startsWith('+')
              ? Colors.green
              : line.startsWith('-')
              ? Theme.of(context).colorScheme.error
              : line.startsWith('@@')
              ? Theme.of(context).colorScheme.primary
              : null;
          return Text(
            line.isEmpty ? ' ' : line,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.6,
              color: color,
            ),
          );
        },
      ),
    );
  }
}
