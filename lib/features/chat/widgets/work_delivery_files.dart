import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../../../domain/desktop/workspace_tools.dart';
import '../../../domain/workbench/changes/line_diff.dart';
import '../../../domain/workbench/files/file_reveal.dart';
import '../../../state/work_changes.dart';
import '../../workbench/files/work_file_access.dart';

class WorkDeliveryFiles extends ConsumerWidget {
  const WorkDeliveryFiles({
    super.key,
    required this.conversationId,
    required this.assistantId,
    required this.onOpen,
  });
  final String conversationId, assistantId;
  final ValueChanged<WorkFileChange> onOpen;

  Future<void> _reveal(
    BuildContext context,
    WidgetRef ref,
    WorkFileChange file,
  ) async {
    WorkToolSession? session;
    final token = CancelToken();
    try {
      session = await openDeliverySession(ref, file, token);
      // Use the same scope checks as viewing the file before handing its path to the OS.
      await session.call('coding_read_file', {
        'scope': file.scope,
        'path': file.path,
        'encoding': 'base64',
      }, token);
      if (session is! WorkspaceToolSession) throw StateError('远端文件请在工作台查看');
      final scope = session.workspace.scopes.firstWhere(
        (scope) => scope.name == file.scope,
      );
      final root = p.isAbsolute(scope.path)
          ? scope.path
          : p.join(session.workspace.root, scope.path);
      final resolved = p.normalize(p.join(root, file.path));
      if (!p.isWithin(root, resolved)) throw StateError('文件路径超出工作区');
      final clean = resolved.startsWith(r'\\?\UNC\')
          ? r'\\' + resolved.substring(8)
          : resolved.startsWith(r'\\?\')
          ? resolved.substring(4)
          : resolved;
      await revealWorkFile(clean);
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      await session?.close();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changes = ref.watch(workChangesProvider);
    final files = finalDeliveryFiles(changes, conversationId, assistantId);
    if (files.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final desktop =
        !kIsWeb &&
        [
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        ].contains(defaultTargetPlatform);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '交付文件 · ${files.length}',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          for (final file in files)
            Builder(
              builder: (context) {
                final diff = file.beforeKnown
                    ? buildLineDiff(file.before, file.after)
                    : null;
                final added = diff
                    ?.where((line) => line.kind == DiffLineKind.added)
                    .length;
                final removed = diff
                    ?.where((line) => line.kind == DiffLineKind.removed)
                    .length;
                final local =
                    (jsonDecode(file.target) as Map)['kind'] == 'local';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: colors.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: colors.outlineVariant),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => onOpen(file),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                        child: Row(
                          children: [
                            Icon(
                              Icons.insert_drive_file_outlined,
                              color: colors.primary,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    file.path,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w500),
                                  ),
                                  const SizedBox(height: 4),
                                  if (diff != null)
                                    Tooltip(
                                      message: '本轮保存的文件改动；点击打开当前文件',
                                      child: Wrap(
                                        spacing: 10,
                                        children: [
                                          Text(
                                            '+$added 行',
                                            style: const TextStyle(
                                              color: Color(0xFF238636),
                                              fontSize: 12,
                                            ),
                                          ),
                                          Text(
                                            '−$removed 行',
                                            style: TextStyle(
                                              color: colors.error,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  else
                                    Tooltip(
                                      message: '缺少修改前版本，无法计算真实增删行数',
                                      child: Text(
                                        '增删行数未统计',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '在工作台查看',
                              onPressed: () => onOpen(file),
                              icon: const Icon(Icons.open_in_new, size: 19),
                            ),
                            if (local && desktop)
                              IconButton(
                                tooltip: '打开所在目录',
                                onPressed: () => _reveal(context, ref, file),
                                icon: const Icon(
                                  Icons.folder_open_outlined,
                                  size: 20,
                                ),
                              )
                            else
                              IconButton(
                                tooltip: '复制文件位置',
                                onPressed: () => Clipboard.setData(
                                  ClipboardData(
                                    text: '${file.targetLabel} / ${file.path}',
                                  ),
                                ),
                                icon: const Icon(Icons.copy_outlined, size: 18),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
