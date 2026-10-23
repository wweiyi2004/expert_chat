import 'package:flutter/material.dart';
import '../../../data/settings_state.dart';

class MediaCapabilitiesOverview extends StatelessWidget {
  const MediaCapabilitiesOverview({super.key, required this.settings});
  final SettingsState settings;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前可用能力', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in [
                  (
                    Icons.image_search_outlined,
                    '识图',
                    settings.config.capabilities.supportsVision
                        ? '当前模型'
                        : settings.visionConfigured
                        ? '独立视觉服务'
                        : '待配置',
                  ),
                  (
                    Icons.auto_awesome_outlined,
                    '生图',
                    settings.imageGenerationConfigured ? '已配置' : '待配置',
                  ),
                  (
                    Icons.mic_none_outlined,
                    '语音输入',
                    settings.asrConfigured ? '云端识别' : '系统识别',
                  ),
                  (
                    Icons.volume_up_outlined,
                    '朗读',
                    settings.ttsConfigured ? '云端语音' : '系统语音',
                  ),
                  (
                    Icons.description_outlined,
                    '文件',
                    settings.supportsDocumentEdit ? '读取与编辑' : '文本提取',
                  ),
                ])
                  Chip(
                    avatar: Icon(item.$1, size: 16),
                    label: Text(
                      '${item.$2} · ${item.$3}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '聊天与工作共用这些能力。视频理解尚未接入；识图能力会随所选模型变化。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
