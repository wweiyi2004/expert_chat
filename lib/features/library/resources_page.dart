import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../chat/widgets/library_picker_sheet.dart';
import '../projects/projects_page.dart';
import 'generation_history_page.dart';

/// One place to manage reusable content; attaching content stays in the composer.
class ResourcesPage extends StatelessWidget {
  const ResourcesPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('资料')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '管理项目、常用素材和生成记录',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            for (final entry in [
              (
                Icons.folder_outlined,
                '项目',
                '按项目整理会话、说明和关联文档',
                const ProjectsPage(),
              ),
              (
                Icons.photo_library_outlined,
                '素材库',
                '搜索、预览和管理已保存的图片与文件',
                const LibraryPage(),
              ),
              (
                Icons.restore_rounded,
                '生图记录',
                '查看生成参数，对比图片版本或再次生成',
                const GenerationHistoryPage(),
              ),
            ])
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  leading: Icon(entry.$1),
                  title: Text(entry.$2),
                  subtitle: Text(entry.$3),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => entry.$4)),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('素材库')),
    body: LibraryBrowser(
      repository: ref.watch(libraryRepositoryProvider),
      maxCount: 0,
      manageOnly: true,
    ),
  );
}
