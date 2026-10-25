import 'package:expert_chat/core/app_toast.dart';
import 'text_value_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/role_evolution.dart';
import '../../../state/settings_controller.dart';
import 'role_validation_panel.dart';

class RoleEvolutionPanel extends ConsumerWidget {
  const RoleEvolutionPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidates = ref.watch(roleEvolutionProvider);
    Future<void> action(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error) {
        if (context.mounted) {
          AppToastMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    }

    return ExpansionTile(
      key: const ValueKey('role-evolution-panel'),
      dense: false,
      minTileHeight: 0,
      tilePadding: const EdgeInsets.symmetric(vertical: 8),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('待验证角色与版本（${candidates.length}）'),
          const SizedBox(height: 4),
          Text(
            '先检索 → 提案 → 正常权限试用 → 产物版本验收 → 复用库',
            key: const ValueKey('role-evolution-description'),
            style:
                ListTileTheme.of(context).subtitleTextStyle ??
                Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      children: [
        const RoleValidationPanel(),
        if (candidates.isEmpty)
          const ListTile(
            dense: false,
            minTileHeight: 0,
            minVerticalPadding: 8,
            title: Text('暂无待验证角色'),
            subtitle: Text(
              '工作代理可调用 role_library_search 与 role_propose。提案不会自动启用或增加工具权限。',
            ),
          ),
        for (final candidate in candidates)
          ExpansionTile(
            dense: false,
            minTileHeight: 0,
            tilePadding: const EdgeInsets.symmetric(vertical: 8),
            title: Text(
              '${candidate.role.name} · v${candidate.version} · ${candidate.disabled
                  ? '禁用'
                  : candidate.verified
                  ? '已有版本证据'
                  : '待验证'}',
            ),
            subtitle: Text(candidate.role.when),
            children: [
              ListTile(
                dense: false,
                minTileHeight: 0,
                minVerticalPadding: 8,
                title: const Text('来源与能力绑定'),
                subtitle: SelectableText(
                  '${candidate.source}\n模型：${candidate.role.model.isEmpty ? '允许池内自动选择' : candidate.role.model}\n所需工具：${candidate.requiredTools.join(', ')}\nID：${candidate.role.id}',
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(candidate.role.instructions),
              ),
              for (final evidence in candidate.evidence)
                ListTile(
                  dense: false,
                  minTileHeight: 0,
                  minVerticalPadding: 8,
                  title: Text(
                    '试用 ${evidence['taskId']} · v${evidence['version']} · ${evidence['success'] == true ? '成功' : '失败'}',
                  ),
                  subtitle: Text(
                    '${evidence['summary']}\n产物版本：${evidence['artifacts']}\n结果版本：${evidence['resultHash'] ?? ''}\n验收：${evidence['acceptance'] ?? '待用户审阅'}',
                  ),
                  trailing:
                      evidence['success'] != true ||
                          evidence['version'] != candidate.version
                      ? null
                      : TextButton(
                          child: const Text('验收证据'),
                          onPressed: () => action(() async {
                            final result = await showDialog<String>(
                              context: context,
                              builder: (_) => TextValueDialog(
                                title: '验收角色试用结果',
                                initialText: '',
                                label: '具体通过依据（至少 8 字符）',
                                description:
                                    '${evidence['summary']}\n结果版本：${evidence['resultHash'] ?? evidence['artifacts']}',
                                minLines: 2,
                                maxLines: 5,
                                maxLength: 2000,
                              ),
                            );
                            if (result != null) {
                              await ref
                                  .read(roleEvolutionProvider.notifier)
                                  .acceptEvidence(
                                    candidate.role.id,
                                    candidate.version,
                                    evidence['taskId'] as String,
                                    result,
                                  );
                            }
                          }),
                        ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => action(() async {
                      final result = await showDialog<String>(
                        context: context,
                        builder: (_) => TextValueDialog(
                          title: '修改候选指令（重新验证）',
                          initialText: candidate.role.instructions,
                          label: '角色指令',
                          minLines: 4,
                          maxLines: 10,
                        ),
                      );
                      if (result != null &&
                          result.trim().isNotEmpty &&
                          result.length <= 24000) {
                        await ref
                            .read(roleEvolutionProvider.notifier)
                            .revise(
                              candidate.role.id,
                              candidate.role.copyWith(
                                instructions: result.trim(),
                              ),
                            );
                      }
                    }),
                    child: const Text('修改指令'),
                  ),
                  TextButton(
                    onPressed: () => action(
                      () => ref
                          .read(roleEvolutionProvider.notifier)
                          .revise(
                            candidate.role.id,
                            candidate.role,
                            disabled: !candidate.disabled,
                          ),
                    ),
                    child: Text(candidate.disabled ? '允许试用' : '禁用'),
                  ),
                  FilledButton(
                    onPressed: !candidate.verified || candidate.disabled
                        ? null
                        : () => action(() async {
                            final current = ref
                                .read(settingsControllerProvider)
                                .requireValue
                                .effectiveSubagentRoles;
                            final previous = current
                                .where((r) => r.id == candidate.role.id)
                                .firstOrNull;
                            if (previous != null) {
                              final replace = await showDialog<bool>(
                                context: context,
                                builder: (dialog) => AlertDialog(
                                  scrollable: true,
                                  title: const Text('替换复用库中的现有角色？'),
                                  content: SizedBox(
                                    width: 600,
                                    child: SingleChildScrollView(
                                      child: SelectableText(
                                        '当前用户版本：${previous.name}\n${previous.instructions}\n\n待采用候选 v${candidate.version}：${candidate.role.name}\n${candidate.role.instructions}',
                                      ),
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialog, false),
                                      child: const Text('保留当前角色'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(dialog, true),
                                      child: const Text('采用已验收候选'),
                                    ),
                                  ],
                                ),
                              );
                              if (replace != true) return;
                            }
                            final latest = ref
                                .read(settingsControllerProvider)
                                .requireValue
                                .effectiveSubagentRoles;
                            final latestPrevious = latest
                                .where((r) => r.id == candidate.role.id)
                                .firstOrNull;
                            if (latestPrevious?.toJson().toString() !=
                                previous?.toJson().toString()) {
                              throw StateError('角色在审阅期间已改变，请重新核对');
                            }
                            await ref
                                .read(settingsControllerProvider.notifier)
                                .setSubagentRoles([
                                  ...latest.where(
                                    (r) => r.id != candidate.role.id,
                                  ),
                                  candidate.role.copyWith(
                                    enabled: true,
                                    version: candidate.version,
                                    source: candidate.source,
                                    requiredTools: candidate.requiredTools,
                                    validation: candidate.evidence
                                        .where(
                                          (e) =>
                                              e['version'] ==
                                                  candidate.version &&
                                              (e['acceptance'] as String? ?? '')
                                                  .isNotEmpty,
                                        )
                                        .map(
                                          (e) =>
                                              '${e['acceptedBy'] ?? 'user'}: ${e['acceptance']}; ${e['resultHash'] ?? e['artifacts']}',
                                        )
                                        .join('\n'),
                                  ),
                                ]);
                          }),
                    child: const Text('加入复用库'),
                  ),
                  TextButton(
                    onPressed: () => action(
                      () => ref
                          .read(roleEvolutionProvider.notifier)
                          .delete(candidate.role.id),
                    ),
                    child: const Text('删除候选'),
                  ),
                ],
              ),
              for (final previous in candidate.history.reversed)
                TextButton(
                  onPressed: () => action(
                    () => ref
                        .read(roleEvolutionProvider.notifier)
                        .rollback(
                          candidate.role.id,
                          previous['version'] as int,
                        ),
                  ),
                  child: Text('回退至 v${previous['version']}（创建新版本并重新验证）'),
                ),
            ],
          ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '证据由真实执行端记录，模型不能自行宣称通过。指令修改或回退会使旧证据失效；用户已修改的复用角色不会被自动覆盖。复用库原有开关、删除与编辑继续有效。',
          ),
        ),
      ],
    );
  }
}
