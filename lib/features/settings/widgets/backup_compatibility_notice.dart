import 'package:flutter/material.dart';
import '../../../data/full_backup_service.dart';

class BackupCompatibilityNotice extends StatelessWidget {
  const BackupCompatibilityNotice({super.key, required this.preview});
  final BackupPreview preview;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            preview.requiresUpgrade ? '旧版备份已准备好转换' : '备份结构兼容',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (preview.requiresUpgrade) ...[
            const SizedBox(height: 8),
            Text(
              preview.sourceSchemaVersion == 15
                  ? '导入时升级结构并创建副本。旧版会话将放入“未归类”，不补造项目或生图版本记录。'
                  : '导入时升级结构并创建副本，保留项目和生图记录。旧记录没有接口格式，再生成时使用当前配置。',
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '数据版本 ${preview.sourceSchemaVersion} → ${preview.targetSchemaVersion}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
