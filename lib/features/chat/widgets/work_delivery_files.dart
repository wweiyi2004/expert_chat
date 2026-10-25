import 'package:expert_chat/core/app_toast.dart';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../domain/desktop/workspace_tools.dart';
import '../../../domain/workbench/changes/line_diff.dart';
import '../../../domain/workbench/files/file_reveal.dart';
import '../../../state/work_changes.dart';
import '../../workbench/files/work_file_access.dart';
import '../../../core/prototype_widgets.dart';

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
      final clean = await authorizedDeliveryLocalPath(session, file, token);
      await revealWorkFile(clean);
    } catch (error) {
      if (context.mounted) {
        AppToastMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      await session?.close();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = finalDeliveryFiles(
      ref.watch(workChangesProvider),
      conversationId,
      assistantId,
    );
    if (files.isEmpty) return const SizedBox.shrink();
    final c = PrototypeColors.of(context);
    final desktop =
        !kIsWeb &&
        [
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        ].contains(defaultTargetPlatform);
    final mono = Theme.of(context).textTheme.bodySmall!.copyWith(
      fontSize: 12,
      fontFamily: 'monospace',
      fontFamilyFallback: const [
        'NotoSansSC',
        'Microsoft YaHei',
        'PingFang SC',
      ],
    );
    return Container(
      key: const ValueKey('work-delivery-group'),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: c.panel,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '交付文件 · ${files.length}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          for (final file in files)
            Builder(
              builder: (context) {
                final diff =
                    file.beforeKnown && file.textSnapshot && file.after != null
                    ? buildLineDiff(file.before, file.after!)
                    : null;
                final added = diff
                    ?.where((l) => l.kind == DiffLineKind.added)
                    .length;
                final removed = diff
                    ?.where((l) => l.kind == DiffLineKind.removed)
                    .length;
                var local = false;
                try {
                  local = (jsonDecode(file.target) as Map)['kind'] == 'local';
                } catch (_) {}
                return Container(
                  key: ValueKey('work-delivery-row-${file.id}'),
                  decoration: BoxDecoration(
                    color: c.surface,
                    border: Border(top: BorderSide(color: c.line)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Tooltip(
                            message: file.path,
                            child: InkWell(
                              onTap: () => onOpen(file),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Text(
                                  file.path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: mono,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (diff != null) ...[
                          Text(
                            '+$added',
                            style: mono.copyWith(color: c.success),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '−$removed',
                            style: mono.copyWith(color: c.confirmation),
                          ),
                        ] else
                          Tooltip(
                            message: '缺少修改前版本，无法计算真实增删行数',
                            child: Text(
                              '—',
                              style: mono.copyWith(color: c.faint),
                            ),
                          ),
                        const SizedBox(width: 8),
                        PrototypeButton(
                          label: '在工作台预览',
                          small: true,
                          onPressed: () => onOpen(file),
                        ),
                        const SizedBox(width: 8),
                        if (local && desktop)
                          PrototypeButton(
                            label: '打开位置',
                            small: true,
                            onPressed: () => _reveal(context, ref, file),
                          )
                        else
                          PrototypeButton(
                            label: '复制位置',
                            small: true,
                            onPressed: () => Clipboard.setData(
                              ClipboardData(
                                text: '${file.targetLabel} / ${file.path}',
                              ),
                            ),
                          ),
                      ],
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
