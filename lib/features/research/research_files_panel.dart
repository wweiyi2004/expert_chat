import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../domain/research/research_files.dart';
import '../../domain/research/shell_quoting.dart';
import '../../state/research_files_controller.dart';
import '../../state/research_terminal_controller.dart';

class ResearchFilesPanel extends ConsumerStatefulWidget {
  const ResearchFilesPanel({super.key});
  @override
  ConsumerState<ResearchFilesPanel> createState() => _ResearchFilesPanelState();
}

class _ResearchFilesPanelState extends ConsumerState<ResearchFilesPanel> {
  final _filter = TextEditingController();
  bool _transfers = false;
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted && ref.read(researchTerminalProvider).isConnected) {
        ref.read(researchFilesProvider.notifier).load();
      }
    });
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    try {
      await work();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _upload() async {
    final generation = ref.read(researchTerminalProvider).connectionGeneration;
    final selected = await FilePicker.pickFiles();
    if (selected == null ||
        !mounted ||
        ref.read(researchTerminalProvider).connectionGeneration != generation) {
      return;
    }
    final file = selected.files.single;
    if (file.path == null) throw StateError('无法读取本地文件路径');
    final name = file.name.replaceAll(RegExp(r'[/\\\x00]'), '_');
    final remote = p.posix.join(
      ref.read(researchFilesProvider).directory,
      name,
    );
    await ref
        .read(researchFilesProvider.notifier)
        .transfer(local: file.path!, remote: remote, upload: true);
  }

  Future<void> _download(ResearchRemoteFile file) async {
    final generation = ref.read(researchTerminalProvider).connectionGeneration;
    final nativeMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final safeName = file.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final String? target;
    if (nativeMobile) {
      final dir = await getTemporaryDirectory();
      target = p.join(
        dir.path,
        'research-${DateTime.now().microsecondsSinceEpoch}-$safeName',
      );
    } else {
      target = await FilePicker.saveFile(
        fileName: safeName,
        dialogTitle: '下载远程文件',
      );
    }
    if (target == null ||
        !mounted ||
        ref.read(researchTerminalProvider).connectionGeneration != generation) {
      return;
    }
    await ref
        .read(researchFilesProvider.notifier)
        .transfer(local: target, remote: file.path, upload: false);
    if (nativeMobile && mounted) {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(target)], subject: file.name),
      );
    }
  }

  Future<void> _edit(ResearchRemoteFile file) async {
    final files = ref.read(researchTerminalProvider.notifier).files;
    final generation = ref.read(researchTerminalProvider).connectionGeneration;
    final text = await files.readText(file.path);
    if (!mounted ||
        ref.read(researchTerminalProvider).connectionGeneration != generation) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RemoteEditor(
          file: file,
          files: files,
          initial: text,
          generation: generation,
        ),
      ),
    );
  }

  Future<void> _mkdir() async {
    final generation = ref.read(researchTerminalProvider).connectionGeneration;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (name == null ||
        !mounted ||
        ref.read(researchTerminalProvider).connectionGeneration != generation) {
      return;
    }
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000')) {
      throw ArgumentError('请输入有效的单层文件夹名称');
    }
    final state = ref.read(researchFilesProvider);
    await ref
        .read(researchTerminalProvider.notifier)
        .files
        .mkdir(p.posix.join(state.directory, name));
    if (mounted) await ref.read(researchFilesProvider.notifier).load();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(researchFilesProvider);
    final connected = ref.watch(
      researchTerminalProvider.select((s) => s.isConnected),
    );
    final ctrl = ref.read(researchFilesProvider.notifier);
    final entries = state.entries
        .where((e) => e.name.toLowerCase().contains(_filter.text.toLowerCase()))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('文件')),
                    ButtonSegment(value: true, label: Text('传输')),
                  ],
                  selected: {_transfers},
                  onSelectionChanged: (v) =>
                      setState(() => _transfers = v.first),
                ),
              ),
            ],
          ),
        ),
        if (_transfers)
          Expanded(
            child: state.transfers.isEmpty
                ? const Center(child: Text('暂无传输任务'))
                : ListView(
                    children: [
                      for (final t in state.transfers)
                        ListTile(
                          leading: Icon(
                            t.upload
                                ? Icons.upload_file
                                : Icons.download_outlined,
                          ),
                          title: Text(
                            p.posix.basename(t.remote),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(switch (t.status) {
                                ResearchTransferStatus.running =>
                                  '${t.bytes} / ${t.total < 0 ? '?' : t.total} 字节',
                                ResearchTransferStatus.done => '已完成',
                                ResearchTransferStatus.cancelled => '已取消',
                                ResearchTransferStatus.failed =>
                                  t.error ?? '传输失败',
                              }),
                              if (t.status == ResearchTransferStatus.running)
                                LinearProgressIndicator(
                                  value: t.total > 0
                                      ? (t.bytes / t.total).clamp(0, 1)
                                      : null,
                                ),
                            ],
                          ),
                          trailing: t.status == ResearchTransferStatus.running
                              ? IconButton(
                                  tooltip: '取消传输',
                                  onPressed: () => ctrl.cancel(t.id),
                                  icon: const Icon(Icons.close),
                                )
                              : t.status != ResearchTransferStatus.done
                              ? IconButton(
                                  tooltip: '重试传输',
                                  onPressed: connected
                                      ? () => _run(() => ctrl.retry(t))
                                      : null,
                                  icon: const Icon(Icons.refresh),
                                )
                              : null,
                        ),
                    ],
                  ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上级目录',
                  onPressed: connected && !state.loading
                      ? () => ctrl.load(p.posix.dirname(state.directory))
                      : null,
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: Tooltip(
                    message: state.directory,
                    child: Text(
                      state.directory,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新文件',
                  onPressed: connected && !state.loading
                      ? () => ctrl.load()
                      : null,
                  icon: const Icon(Icons.refresh),
                ),
                PopupMenuButton<String>(
                  enabled: connected,
                  onSelected: (v) => _run(() async {
                    if (v == 'upload') {
                      await _upload();
                    }
                    if (v == 'mkdir') {
                      await _mkdir();
                    }
                    if (v == 'terminal') {
                      ref
                          .read(researchTerminalProvider.notifier)
                          .writeUserInput(
                            'cd -- ${shellSingleQuote(state.directory)}\r',
                          );
                    }
                  }),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'upload',
                      child: Text('上传文件（同名文件不覆盖）'),
                    ),
                    PopupMenuItem(value: 'mkdir', child: Text('新建文件夹')),
                    PopupMenuItem(value: 'terminal', child: Text('终端进入此目录')),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _filter,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: '筛选文件',
              ),
            ),
          ),
          if (state.loading) const LinearProgressIndicator(),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('文件通道：${state.error}'),
            ),
          Expanded(
            child: !connected
                ? const Center(child: Text('连接 SSH 后浏览远程文件'))
                : entries.isEmpty && !state.loading
                ? const Center(child: Text('目录为空或没有匹配项'))
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (_, i) {
                      final e = entries[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          e.directory
                              ? Icons.folder_outlined
                              : Icons.description_outlined,
                        ),
                        title: Text(
                          e.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: e.directory ? null : Text('${e.size} 字节'),
                        onTap: () => e.directory
                            ? ctrl.load(e.path)
                            : _run(() => _edit(e)),
                        trailing: e.directory
                            ? null
                            : IconButton(
                                tooltip: '下载文件',
                                onPressed: () => _run(() => _download(e)),
                                icon: const Icon(Icons.download_outlined),
                              ),
                      );
                    },
                  ),
          ),
        ],
      ],
    );
  }
}

class _RemoteEditor extends ConsumerStatefulWidget {
  const _RemoteEditor({
    required this.file,
    required this.files,
    required this.initial,
    required this.generation,
  });
  final ResearchRemoteFile file;
  final ResearchFiles files;
  final String initial;
  final int generation;
  @override
  ConsumerState<_RemoteEditor> createState() => _RemoteEditorState();
}

class _RemoteEditorState extends ConsumerState<_RemoteEditor> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );
  late String _saved = widget.initial;
  bool _saving = false;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (ref.read(researchTerminalProvider).connectionGeneration !=
        widget.generation) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('连接已变化，请重新打开文件')));
      return;
    }
    setState(() => _saving = true);
    final content = _text.text;
    try {
      await widget.files.saveText(widget.file.path, content, original: _saved);
      if (mounted) {
        setState(() => _saved = content);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已保存到远程主机')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving && _text.text == _saved,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop || _saving) return;
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('放弃未保存的修改？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      if (discard == true && mounted) {
        setState(() => _saved = _text.text);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.file.name),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _text,
          expands: true,
          maxLines: null,
          minLines: null,
          readOnly: _saving,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(border: InputBorder.none),
        ),
      ),
    ),
  );
}
