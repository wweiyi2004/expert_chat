import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../shared/recovery_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../data/backup_file.dart';
import '../../data/full_backup_service.dart';
import '../../state/chat_controller.dart';
import '../../state/character_controller.dart';
import '../../state/memory_controller.dart';
import '../../state/settings_controller.dart';
import '../../state/study_controller.dart';
import '../../state/world_info_controller.dart';
import 'widgets/backup_compatibility_notice.dart';

class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});
  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  bool _busy = false;
  bool _preferences = false;
  BackupPreview? _preview;
  String? _notice;
  Object? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _notice = null;
      _error = null;
    });
    try {
      await ref.read(chatControllerProvider.future);
      await ref.read(chatControllerProvider.notifier).prepareDataMaintenance();
      if (ref.read(studyControllerProvider.notifier).hasActiveRequest) {
        throw StateError('请先等待学习内容生成结束。');
      }
      await ref.read(memoryRepositoryProvider).withMaintenance(action);
      if (mounted) ref.invalidate(memoryControllerProvider);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() => _run(() async {
    final bytes = await ref.read(fullBackupServiceProvider).exportBackup();
    final path = await BackupFile().save(bytes);
    if (mounted) {
      setState(() => _notice = path == null ? '已取消导出。' : '备份已保存：$path');
    }
  });

  Future<void> _pick() => _run(() async {
    setState(() => _preview = null);
    final bytes = await BackupFile().pick();
    if (bytes == null) return;
    final preview = await ref.read(fullBackupServiceProvider).preview(bytes);
    if (mounted) {
      setState(() {
        _preview = preview;
        _preferences = false;
      });
    }
  });

  Future<void> _restore() async {
    final preview = _preview;
    if (preview == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入备份副本？'),
        content: Text(
          '不会删除或覆盖现有会话、项目和素材。每次导入都会创建新副本。'
          '\n${_preferences ? '将覆盖所包含的界面、提示词及任务偏好设置。' : '保留当前所有设置。'}'
          '\n不会恢复服务商密钥，或自动执行备份中的远程任务。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导入副本'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await ref
          .read(fullBackupServiceProvider)
          .restoreCopies(preview, restorePreferences: _preferences);
      ref.invalidate(chatControllerProvider);
      ref.invalidate(studyControllerProvider);
      ref.invalidate(characterCardsProvider);
      ref.invalidate(worldInfoProvider);
      if (_preferences) ref.invalidate(settingsControllerProvider);
      if (mounted) {
        setState(() {
          _preview = null;
          _notice = '恢复完成：已新增副本，原有数据保留。';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('完整备份与恢复')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('备份未加密，请妥善保管。'),
              const ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('备份范围与注意事项'),
                childrenPadding: EdgeInsets.only(bottom: 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('包含会话与分支、角色和世界书、学习记录、记忆、素材、项目、生图记录及常用偏好。'),
                  SizedBox(height: 8),
                  Text('不包含单独保存的密钥和服务连接配置。聊天或提示词中手动写入的敏感内容仍会保留。'),
                  SizedBox(height: 8),
                  Text('远程附件链接不会下载为本地文件，离线时可能无法使用。'),
                  SizedBox(height: 8),
                  Text('恢复时创建副本，不覆盖现有聊天和资料，也不会自动继续未完成的远程任务。'),
                  SizedBox(height: 8),
                  Text('支持数据结构 15、16 的完整备份；已知旧结构会先转换。更新版本需先升级应用。'),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _busy || kIsWeb ? null : _export,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('导出完整备份'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || kIsWeb ? null : _pick,
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('选择备份并预览'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('备份文件最大 128 MB。'),
              if (kIsWeb) const Text('完整备份和恢复暂仅支持桌面、移动应用。'),
              if (_preview case final preview?) ...[
                const SizedBox(height: 24),
                Text('已通过校验 · ${preview.createdAt}'),
                const SizedBox(height: 12),
                BackupCompatibilityNotice(preview: preview),
                const SizedBox(height: 12),
                Text(
                  '会话 ${preview.count('conversations')} · 消息 ${preview.count('messages')}\n'
                  '素材 ${preview.count('library_items')} · 记忆 ${preview.memories}\n'
                  '学习条目 ${preview.count('study_entities')} · 项目 ${preview.count('projects')}\n'
                  '生图记录 ${preview.count('generation_records')}',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同时恢复常用偏好（覆盖当前值）'),
                  value: _preferences,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _preferences = v!),
                ),
                FilledButton(
                  onPressed: _busy ? null : _restore,
                  child: const Text('导入为副本'),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: RecoveryNotice(
                    error: _error!,
                    title: '备份操作未完成',
                    guidance: '请保留备份文件。确认原因后，再选择导出、预览或导入。',
                  ),
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: SelectableText(_notice!),
                ),
            ],
          ),
          if (_busy) ...[
            const ModalBarrier(dismissible: false, color: Color(0x55000000)),
            const Center(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('正在处理本地数据，请勿关闭应用…'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
