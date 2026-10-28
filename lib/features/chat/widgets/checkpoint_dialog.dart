import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../domain/host/host_client.dart';
import '../../../domain/host/wire_models.dart';
import '../../../state/chat_controller.dart';
import '../../tui_bridge/backend.dart';

Future<void> showCheckpointDialog(BuildContext context, String session) =>
    showDialog<void>(
      context: context,
      builder: (_) => _CheckpointDialog(session: session),
    );

class _CheckpointDialog extends ConsumerStatefulWidget {
  const _CheckpointDialog({required this.session});
  final String session;
  @override
  ConsumerState<_CheckpointDialog> createState() => _CheckpointDialogState();
}

class _CheckpointDialogState extends ConsumerState<_CheckpointDialog> {
  List<Map<String, dynamic>> points = [];
  Map<String, dynamic>? preview;
  String? selected, error, result;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, Object?> args,
  ) async {
    final values = {'session_id': widget.session, ...args};
    final client = HostClient.current;
    if (client != null) {
      return client.invoke(
        'checkpoint.$method',
        values,
        timeout: const Duration(minutes: 2),
      );
    }
    return Map<String, dynamic>.from(
      await ControllerBridgeBackend(
        ProviderScope.containerOf(context, listen: false),
      ).invoke('checkpoint.$method', values),
    );
  }

  Future<void> load() async {
    try {
      final data = await call('list', {});
      if (mounted) {
        setState(() {
          points = wireRows(data['checkpoints']).reversed.toList();
          selected = points.firstOrNull?['id'] as String?;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> inspect() async {
    if (selected == null) return;
    setState(() {
      busy = true;
      error = null;
      preview = null;
      result = null;
    });
    try {
      final data = await call('preview', {'message_id': selected});
      if (mounted) setState(() => preview = data);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restore(String mode) async {
    final review = preview;
    if (review == null) return;
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final data = await call('restore', {
        'message_id': review['message_id'],
        'fingerprint': review['fingerprint'],
        'mode': mode,
        'confirmed': true,
      });
      await HostClient.current?.refresh(force: true);
      if (data['branch_created'] == true && mounted) {
        await ref
            .read(chatControllerProvider.notifier)
            .selectConversation(data['session_id'] as String);
      }
      if (mounted) {
        setState(() {
          preview = null;
          result =
              '${data['branch_created'] == true
                  ? '已创建新分支'
                  : data['conversation_restored'] == true
                  ? '会话已回到所选消息之前'
                  : '会话位置保持不变'}；'
              '已回退 ${(data['restored_files'] as List).length} 条文件记录。'
              '${(data['skipped_files'] as List).isEmpty ? '' : '部分文件未回退，请到改动面板核对。'}\n${data['warning']}';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = wireRows(preview?['files']);
    final active =
        ref
            .watch(chatControllerProvider)
            .value
            ?.runningConversationIds
            .contains(widget.session) ==
        true;
    return AlertDialog(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('检查点与分支'),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('检查点位于所选用户消息之前。会话回退保留历史分支；新分支保留原会话。'),
              const SizedBox(height: 12),
              if (points.isNotEmpty)
                DropdownButton<String>(
                  isExpanded: true,
                  value: selected,
                  items: [
                    for (final point in points)
                      DropdownMenuItem(
                        value: point['id'] as String,
                        child: Text(
                          point['title'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (id) => setState(() {
                          selected = id;
                          preview = null;
                        }),
                ),
              TextButton(
                onPressed: busy || selected == null ? null : inspect,
                child: const Text('查看回退范围'),
              ),
              if (preview != null) ...[
                Text(preview!['warning'] as String),
                for (final file in files)
                  ExpansionTile(
                    title: Text(file['path'] as String),
                    subtitle: Text(
                      file['restorable'] == true
                          ? file['new_file'] == true
                                ? '回退将删除此新增文件'
                                : '按当前文件 SHA 核验后回退'
                          : '无法回退此记录',
                    ),
                    children: [
                      SelectableText(
                        '回退前：\n${file['after'] ?? '无文本快照'}\n\n回退后：\n${file['before'] ?? '文件不存在'}',
                      ),
                      if (file['preview_truncated'] == true)
                        const Text('长文件预览已截断；完整内容可在改动面板查看。'),
                    ],
                  ),
                if (files.isEmpty) const Text('此检查点之后没有可追溯的文件改动记录。'),
              ],
              if (active) const Text('会话正在执行，请先停止任务再回退。'),
              if (busy) const LinearProgressIndicator(),
              if (result != null) SelectableText(result!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        for (final entry in const {
          'branch': '新分支',
          'conversation': '仅回退会话',
          'files': '仅回退文件',
          'both': '回退会话与文件',
        }.entries)
          TextButton(
            onPressed: busy || active || preview == null
                ? null
                : () => restore(entry.key),
            child: Text(entry.value),
          ),
      ],
    );
  }
}
