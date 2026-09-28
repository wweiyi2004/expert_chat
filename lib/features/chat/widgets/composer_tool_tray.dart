import 'package:flutter/material.dart';
import '../../../data/composer_modes.dart';

/// Expandable action tray revealed by the composer “+” button.
class ComposerToolTray extends StatelessWidget {
  const ComposerToolTray({
    super.key,
    required this.imageGenerationConfigured,
    required this.imageMode,
    required this.picking,
    required this.searchMode,
    required this.imageGenMode,
    required this.mcpAvailable,
    required this.mcpSelectedCount,
    required this.documentEditAvailable,
    required this.longTaskAvailable,
    required this.longTaskMode,
    required this.onPickDocuments,
    required this.onPickImages,
    required this.onPickLibrary,
    required this.onToggleImageMode,
    required this.onToggleSearch,
    required this.onSetImageGenMode,
    required this.onPickMcpServers,
    required this.onDocumentEdit,
    required this.onToggleLongTask,
    this.onVoiceConversation,
  });

  final bool imageGenerationConfigured;
  final bool imageMode;
  final bool picking;
  final SearchMode searchMode;
  final ImageGenMode imageGenMode;
  final bool mcpAvailable;
  final int mcpSelectedCount;
  final bool documentEditAvailable;
  final bool longTaskAvailable;
  final bool longTaskMode;
  final VoidCallback? onPickDocuments;
  final VoidCallback? onPickImages;
  final VoidCallback? onPickLibrary;
  final VoidCallback? onToggleImageMode;
  final VoidCallback? onToggleSearch;
  final ValueChanged<ImageGenMode>? onSetImageGenMode;
  final VoidCallback? onPickMcpServers;
  final VoidCallback? onDocumentEdit;
  final VoidCallback? onToggleLongTask;

  /// Opens hands-free voice mode; hidden when null.
  final VoidCallback? onVoiceConversation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final actions = <Widget>[
      _ComposerPlusAction(
        icon: Icons.folder_open_outlined,
        label: '上传文件',
        enabled: onPickDocuments != null && !picking,
        onTap: onPickDocuments,
      ),
      _ComposerPlusAction(
        icon: Icons.image_outlined,
        label: imageMode ? '参考图' : '上传图片',
        enabled: onPickImages != null && !picking,
        onTap: onPickImages,
      ),
      _ComposerPlusAction(
        icon: Icons.photo_library_outlined,
        label: '素材库',
        enabled: onPickLibrary != null && !picking,
        onTap: onPickLibrary,
      ),
      if (imageGenerationConfigured || onSetImageGenMode != null)
        _ComposerPlusAction(
          icon: imageMode ? Icons.auto_awesome : Icons.auto_awesome_outlined,
          label: imageMode ? '图片·生图中' : '图片',
          selected: imageMode,
          enabled: onToggleImageMode != null || onSetImageGenMode != null,
          onTap: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (sheet) => SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (imageGenerationConfigured)
                      ListTile(
                        leading: const Icon(Icons.auto_awesome),
                        title: Text(imageMode ? '退出生图' : '图片生成'),
                        onTap: onToggleImageMode == null
                            ? null
                            : () {
                                Navigator.pop(sheet);
                                onToggleImageMode!();
                              },
                      ),
                    const ListTile(
                      leading: Icon(Icons.chat_bubble_outline),
                      title: Text('回答配图'),
                    ),
                    if (imageMode)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Text('当前为独立生图模式，退出后可设置回答配图。'),
                      )
                    else
                      for (final mode in ImageGenMode.values)
                        ListTile(
                          leading: Icon(
                            imageGenMode == mode
                                ? Icons.check_circle
                                : Icons.radio_button_off,
                          ),
                          selected: imageGenMode == mode,
                          title: Text(switch (mode) {
                            ImageGenMode.off => '关闭配图',
                            ImageGenMode.auto => '自动配图',
                            ImageGenMode.always => '始终配图',
                          }),
                          subtitle: Text(switch (mode) {
                            ImageGenMode.off => '只生成文字回答',
                            ImageGenMode.auto => '由模型判断是否需要生成图片',
                            ImageGenMode.always => '每次回答都尝试生成图片',
                          }),
                          onTap: onSetImageGenMode == null
                              ? null
                              : () {
                                  Navigator.pop(sheet);
                                  onSetImageGenMode!(mode);
                                },
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      if (onVoiceConversation != null)
        _ComposerPlusAction(
          key: const ValueKey('composer-voice-conversation-button'),
          icon: Icons.headset_mic_outlined,
          label: '语音对话',
          enabled: true,
          onTap: onVoiceConversation,
        ),
      if (documentEditAvailable)
        _ComposerPlusAction(
          icon: Icons.edit_document,
          label: '改文档',
          enabled: onDocumentEdit != null,
          onTap: onDocumentEdit,
        ),
      if (mcpAvailable || longTaskAvailable)
        _ComposerPlusAction(
          icon: Icons.tune,
          label: longTaskMode
              ? '高级·后台'
              : mcpSelectedCount > 0
              ? '高级·工具'
              : '高级',
          selected: longTaskMode || mcpSelectedCount > 0,
          enabled: true,
          onTap: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (sheet) => SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ListTile(title: Text('高级执行选项')),
                    if (mcpAvailable)
                      ListTile(
                        leading: const Icon(Icons.extension_outlined),
                        title: const Text('外部工具（MCP）'),
                        subtitle: Text(
                          mcpSelectedCount == 0
                              ? '选择这次对话可使用的工具服务'
                              : '已选择 $mcpSelectedCount 个工具服务',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: onPickMcpServers == null
                            ? null
                            : () {
                                Navigator.pop(sheet);
                                onPickMcpServers!();
                              },
                      ),
                    if (longTaskAvailable)
                      SwitchListTile(
                        secondary: const Icon(Icons.schedule_send_outlined),
                        title: const Text('后台执行'),
                        value: longTaskMode,
                        onChanged: onToggleLongTask == null
                            ? null
                            : (_) {
                                Navigator.pop(sheet);
                                onToggleLongTask!();
                              },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ];
    return Container(
      key: const ValueKey('composer-plus-tray'),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 8.0;
          const columns = 4;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final action in actions)
                SizedBox(width: width, child: action),
            ],
          );
        },
      ),
    );
  }
}

class _ComposerPlusAction extends StatelessWidget {
  const _ComposerPlusAction({
    super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : selected
        ? scheme.primary
        : scheme.onSurface;
    final bg = selected
        ? scheme.primaryContainer.withValues(alpha: 0.7)
        : scheme.surface;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary.withValues(alpha: 0.14)
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 20, color: fg),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
