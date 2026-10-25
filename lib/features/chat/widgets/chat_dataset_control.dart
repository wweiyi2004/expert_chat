import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import '../../../core/prototype_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers.dart';
import '../../../state/chat_controller.dart';
import '../../../data/db/app_database.dart' show Project;

final chatDatasetsProvider = FutureProvider.autoDispose<List<Project>>(
  (ref) => ref.read(projectRepositoryProvider).list(),
);

class ChatDatasetControl extends ConsumerWidget {
  const ChatDatasetControl({
    super.key,
    required this.conversationId,
    this.projectId,
  });
  final String conversationId;
  final String? projectId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = projectId == null ? null : ref.watch(chatDatasetsProvider);
    final selected = projects?.value
        ?.where((p) => p.id == projectId)
        .firstOrNull;
    return PrototypeChip(
      key: const ValueKey('composer-dataset'),
      icon: Icons.library_books_outlined,
      label: selected?.name ?? (projectId == null ? '不引用资料集' : '资料集'),
      onPressed: () async {
        ref.invalidate(chatDatasetsProvider);
        final chosen = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (sheet) => Consumer(
            builder: (context, ref, _) {
              final datasets = ref.watch(chatDatasetsProvider);
              return SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    const ListTile(title: Text('引用资料集')),
                    ListTile(
                      title: const Text('不引用资料集'),
                      selected: projectId == null,
                      onTap: () => Navigator.pop(sheet, ''),
                    ),
                    if (datasets.isLoading) const LinearProgressIndicator(),
                    if (datasets.hasError)
                      ListTile(
                        title: Text('读取失败：${datasets.error}'),
                        onTap: () => ref.invalidate(chatDatasetsProvider),
                      ),
                    for (final project in datasets.value ?? <Project>[])
                      ListTile(
                        title: Text(project.name),
                        selected: project.id == projectId,
                        onTap: () => Navigator.pop(sheet, project.id),
                      ),
                  ],
                ),
              );
            },
          ),
        );
        if (chosen == null) {
          return;
        }
        try {
          await ref
              .read(chatControllerProvider.notifier)
              .assignProject(conversationId, chosen.isEmpty ? null : chosen);
        } catch (error) {
          if (context.mounted) {
            AppToastMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('$error')));
          }
        }
      },
    );
  }
}
