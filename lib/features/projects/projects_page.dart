import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/mode_style.dart';
import '../../core/providers.dart';
import '../../data/db/app_database.dart' show Project;
import '../../data/library_models.dart';
import '../../data/models.dart';
import '../../state/chat_controller.dart';
import '../shared/recovery_notice.dart';
import '../shell/shell_tab.dart';
import 'project_document_page.dart';

class ProjectsPage extends ConsumerStatefulWidget {
  const ProjectsPage({super.key});
  @override
  ConsumerState<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends ConsumerState<ProjectsPage> {
  List<Project> _projects = [];
  Map<String, int> _fileCounts = {};
  List<LibraryItem> _files = [];
  String? _selected;
  bool _initialized = false;
  bool _loading = true;
  bool _loadingFiles = false;
  bool _opening = false;
  bool _showFiles = false;
  bool _allConversations = false;
  int _fileRequest = 0;
  String _query = '';
  Object? _error;
  Object? _fileError;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(projectRepositoryProvider);
      final projects = await repository.list();
      final counts = await repository.fileCounts();
      if (!mounted) return;
      setState(() {
        _projects = projects;
        _fileCounts = counts;
        if (!_initialized) {
          final activeProject = ref
              .read(chatControllerProvider)
              .value
              ?.current
              ?.projectId;
          _selected = projects.any((p) => p.id == activeProject)
              ? activeProject
              : projects.firstOrNull?.id;
          _projects = [
            for (final p in projects)
              if (p.id == _selected) p,
            for (final p in projects)
              if (p.id != _selected) p,
          ];
          _initialized = true;
        } else if (!projects.any((p) => p.id == _selected)) {
          _selected = null;
        }
        _loading = false;
      });
      await _loadFiles();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadFiles() async {
    final version = ++_fileRequest;
    final id = _selected;
    setState(() {
      _files = [];
      _fileError = null;
      _loadingFiles = id != null;
    });
    if (id == null) return;
    try {
      final files = await ref.read(projectRepositoryProvider).linkedFiles(id);
      if (mounted && version == _fileRequest) {
        setState(() {
          _files = files;
          _loadingFiles = false;
        });
      }
    } catch (e) {
      if (mounted && version == _fileRequest) {
        setState(() {
          _fileError = e;
          _loadingFiles = false;
        });
      }
    }
  }

  void _select(String? id) {
    if (_opening || id == _selected) return;
    setState(() {
      _selected = id;
      _allConversations = false;
    });
    _loadFiles();
  }

  Future<void> _edit([Project? project]) async {
    if (_opening || _loading) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final library = await ref
          .read(libraryRepositoryProvider)
          .list(kind: LibraryItemKind.file);
      final selected = project == null
          ? <String>{}
          : (await ref.read(projectRepositoryProvider).fileIds(project.id))
                .toSet();
      if (!mounted) return;
      final saved = await showDialog<String>(
        context: context,
        builder: (_) => _ProjectEditor(
          project: project,
          library: library,
          selected: selected,
        ),
      );
      if (saved != null && mounted) {
        setState(() {
          _selected = saved;
          _initialized = true;
        });
        await _reload();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _delete(Project project) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除项目「${project.name}」？'),
        content: const Text('会话将移至“未归类”，素材和记忆保留。此项目的记忆将不再用于回答。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除项目'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await ref.read(chatControllerProvider.notifier).deleteProject(project.id);
      if (!mounted) return;
      setState(() => _selected = null);
      await _reload();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _assign() async {
    final current = ref.read(chatControllerProvider).value?.current;
    if (current == null || _opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await ref
          .read(chatControllerProvider.notifier)
          .assignProject(current.id, _selected);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _returnToChat() {
    ref.read(shellTabProvider.notifier).set(ShellTab.chat);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _openConversation(Conversation conversation) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await ref
          .read(chatControllerProvider.notifier)
          .selectConversation(conversation.id);
      if (!mounted) return;
      final current = ref.read(chatControllerProvider).requireValue;
      if (current.current?.id != conversation.id ||
          current.current?.messagesLoaded != true) {
        throw StateError(current.error ?? '会话暂时无法读取，请重新加载后再试。');
      }
      _returnToChat();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _newConversation() {
    ref
        .read(chatControllerProvider.notifier)
        .newConversation(projectId: _selected);
    _returnToChat();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider).value;
    final conversations = [
      ...?chat?.conversations.where((c) => c.projectId == _selected),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final project = _projects.where((p) => p.id == _selected).firstOrNull;
    final cards = [
      ..._projects.where(
        (p) => '${p.name} ${p.instructions}'.toLowerCase().contains(
          _query.toLowerCase(),
        ),
      ),
      null,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('项目'),
        actions: [
          IconButton(
            tooltip: '刷新项目',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '新建项目',
            onPressed: _opening ? null : () => _edit(),
            icon: const Icon(Icons.folder_open_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 920;
                    final selector = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          key: const ValueKey('project-search'),
                          onChanged: (v) => setState(() => _query = v),
                          decoration: const InputDecoration(
                            hintText: '查找项目',
                            prefixIcon: Icon(Icons.search),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: ListView.separated(
                            scrollDirection: wide
                                ? Axis.vertical
                                : Axis.horizontal,
                            itemCount: cards.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 10, height: 10),
                            itemBuilder: (_, index) {
                              final p = cards[index];
                              final count =
                                  chat?.conversations
                                      .where((c) => c.projectId == p?.id)
                                      .length ??
                                  0;
                              return SizedBox(
                                width: wide ? null : 220,
                                child: _ProjectCard(
                                  project: p,
                                  selected: _selected == p?.id,
                                  conversations: count,
                                  files: _fileCounts[p?.id] ?? 0,
                                  onTap: _opening ? null : () => _select(p?.id),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    );
                    final details = _details(
                      project,
                      conversations,
                      chat,
                      wide: wide,
                    );
                    return wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(width: 270, child: selector),
                              const SizedBox(width: 24),
                              Expanded(child: details),
                            ],
                          )
                        : Column(
                            children: [
                              SizedBox(height: 190, child: selector),
                              const SizedBox(height: 16),
                              Expanded(child: details),
                            ],
                          );
                  },
                ),
              ),
            ),
    );
  }

  Widget _details(
    Project? project,
    List<Conversation> conversations,
    ChatState? chat, {
    required bool wide,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final latest = conversations.firstOrNull;
    return ListView(
      key: ValueKey('project-details-$_selected'),
      children: [
        const Text('集中管理项目会话、说明和资料。'),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project?.name ?? '未归类',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  project == null
                      ? '这里的对话尚未归入项目，可继续聊天或移入合适的项目。'
                      : (project.instructions.isEmpty
                            ? '添加项目说明和资料，让后续对话共享背景。'
                            : project.instructions),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (latest != null)
                      FilledButton.icon(
                        key: const ValueKey('project-continue'),
                        onPressed: _opening
                            ? null
                            : () => _openConversation(latest),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: const Text('继续最近会话'),
                      ),
                    OutlinedButton.icon(
                      onPressed: _opening ? null : _newConversation,
                      icon: const Icon(Icons.add),
                      label: const Text('在此新建对话'),
                    ),
                    if (project != null)
                      TextButton(
                        onPressed: _opening ? null : () => _edit(project),
                        child: const Text('编辑说明与资料'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: RecoveryNotice(
              error: _error!,
              title: '项目操作未完成',
              onRetry: _reload,
              retryLabel: '重新加载列表',
            ),
          ),
        const SizedBox(height: 24),
        if (!wide && project != null) ...[
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: false,
                label: Text('会话 ${conversations.length}'),
              ),
              ButtonSegment(
                value: true,
                label: Text('资料 ${_fileCounts[project.id] ?? 0}'),
              ),
            ],
            selected: {_showFiles},
            onSelectionChanged: (v) => setState(() => _showFiles = v.first),
          ),
          const SizedBox(height: 16),
        ],
        if (wide || !_showFiles || project == null) ...[
          _ProjectHeading(
            title: '最近会话',
            count: conversations.length,
            action:
                chat?.current == null || chat!.current!.projectId == _selected
                ? null
                : TextButton(
                    onPressed: _opening ? null : _assign,
                    child: const Text('移入当前会话'),
                  ),
          ),
          const SizedBox(height: 8),
          if (conversations.isEmpty)
            const _ProjectEmpty(
              icon: Icons.chat_bubble_outline,
              text: '还没有会话。在此新建对话后，会自动归入这个项目。',
            ),
          for (final conversation
              in (_allConversations ? conversations : conversations.take(5)))
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                key: ValueKey('project-conversation-${conversation.id}'),
                leading: Icon(ModeStyle.icon(conversation.mode)),
                title: Text(
                  conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${ModeStyle.label(conversation.mode)} · ${_shortDate(conversation.updatedAt)}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _opening ? null : () => _openConversation(conversation),
              ),
            ),
          if (conversations.length > 5)
            TextButton(
              onPressed: () =>
                  setState(() => _allConversations = !_allConversations),
              child: Text(
                _allConversations ? '收起会话' : '查看全部 ${conversations.length} 个会话',
              ),
            ),
        ],
        if (project != null && (wide || _showFiles)) ...[
          const SizedBox(height: 20),
          _ProjectHeading(
            title: '关联资料',
            count: _fileCounts[project.id] ?? 0,
            action: TextButton(
              onPressed: () => _edit(project),
              child: const Text('管理资料'),
            ),
          ),
          const SizedBox(height: 8),
          if (_loadingFiles)
            const LinearProgressIndicator()
          else if (_fileError != null)
            RecoveryNotice(error: _fileError!, onRetry: _loadFiles)
          else if (_files.isEmpty)
            const _ProjectEmpty(
              icon: Icons.insert_drive_file_outlined,
              text: '关联素材库中的文档，供项目内的回答参考。',
            )
          else
            for (final file in _files)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  key: ValueKey('project-file-${file.id}'),
                  leading: Icon(
                    Icons.insert_drive_file_outlined,
                    color: scheme.primary,
                  ),
                  title: Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${(file.sizeBytes / 1024).ceil()} KB · 点击预览'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ProjectDocumentPage(item: file),
                    ),
                  ),
                ),
              ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _opening ? null : () => _delete(project),
              child: Text('删除项目', style: TextStyle(color: scheme.error)),
            ),
          ),
        ],
      ],
    );
  }
}

String _shortDate(DateTime value) {
  final local = value.toLocal();
  return '${local.month}月${local.day}日 ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.selected,
    required this.conversations,
    required this.files,
    required this.onTap,
  });
  final Project? project;
  final bool selected;
  final int conversations;
  final int files;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainer,
      child: InkWell(
        key: ValueKey('project-card-${project?.id ?? 'unclassified'}'),
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    project == null
                        ? Icons.chat_bubble_outline
                        : Icons.folder_outlined,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      project?.name ?? '未归类',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (selected) const Icon(Icons.check, size: 18),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '$conversations 个会话 · $files 份资料',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (project != null) ...[
                const SizedBox(height: 6),
                Text(
                  project!.instructions.isEmpty
                      ? '尚未添加项目说明'
                      : project!.instructions,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectHeading extends StatelessWidget {
  const _ProjectHeading({
    required this.title,
    required this.count,
    this.action,
  });
  final String title;
  final int count;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    children: [
      Text('$title（$count）', style: Theme.of(context).textTheme.titleMedium),
      ?action,
    ],
  );
}

class _ProjectEmpty extends StatelessWidget {
  const _ProjectEmpty({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class _ProjectEditor extends ConsumerStatefulWidget {
  const _ProjectEditor({
    this.project,
    required this.library,
    required this.selected,
  });
  final Project? project;
  final List<LibraryItem> library;
  final Set<String> selected;
  @override
  ConsumerState<_ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends ConsumerState<_ProjectEditor> {
  late final _name = TextEditingController(text: widget.project?.name);
  late final _instructions = TextEditingController(
    text: widget.project?.instructions,
  );
  bool _saving = false;
  Object? _error;
  @override
  void dispose() {
    _name.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final id = await ref
          .read(projectRepositoryProvider)
          .save(
            id: widget.project?.id,
            name: _name.text,
            instructions: _instructions.text,
            fileIds: widget.selected.toList(),
          );
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(widget.project == null ? '新建项目' : '编辑项目'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: '项目名称'),
              ),
              TextField(
                controller: _instructions,
                maxLength: 8000,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: '项目说明',
                  helperText: '将随本项目的对话发送给模型。',
                ),
              ),
              const Text('选择素材库文档（最多 20 份）'),
              const ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('资料使用说明'),
                children: [
                  Text('所选文档将用于本项目的回答，每次最多读取 32000 字，超出部分会被截断。图片请在对话中单独添加。'),
                ],
              ),
              if (widget.library.isEmpty) const Text('素材库暂无文档，请先在聊天中导入资料。'),
              for (final item in widget.library)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.name),
                  subtitle: Text('${(item.sizeBytes / 1024).round()} KB'),
                  value: widget.selected.contains(item.id),
                  onChanged: _saving
                      ? null
                      : (v) => setState(() {
                          if (v == true) {
                            widget.selected.add(item.id);
                          } else {
                            widget.selected.remove(item.id);
                          }
                        }),
                ),
              if (_error != null)
                RecoveryNotice(
                  error: _error!,
                  title: '项目尚未保存',
                  guidance: '名称、说明和资料选择仍然保留，检查后可再次保存。',
                ),
            ],
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
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
