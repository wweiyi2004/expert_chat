import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import '../../../core/prototype_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/session_policy.dart';
import '../../../state/model_service_routing.dart';
import '../../../state/settings_controller.dart';
import '../../../state/research_terminal_controller.dart';
import '../../research/research_terminal_page.dart';
import 'work_round_controls.dart';
import 'composer_popover.dart';
import 'settings_field_section.dart';
import '../../workbench/runtime/task_control_panel.dart';

class SessionPolicyControls extends ConsumerWidget {
  const SessionPolicyControls({
    super.key,
    required this.conversationId,
    required this.workMode,
    this.busy = false,
  });
  final String conversationId;
  final bool workMode, busy;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy =
        ref.watch(sessionPolicyProvider)[conversationId] ??
        const SessionPolicy();
    final settings = ref.watch(settingsControllerProvider).value;
    Future<void> save(SessionPolicy value) async {
      try {
        await ref
            .read(sessionPolicyProvider.notifier)
            .save(conversationId, value);
      } catch (error) {
        if (context.mounted) {
          AppToastMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    }

    final research = workMode ? ref.watch(researchTerminalProvider) : null;
    final models = <String>{
      '',
      if (settings != null) ...serviceModelCatalog(settings.profiles),
      if (policy.reviewerModel.isNotEmpty) policy.reviewerModel,
    };
    Widget field(String title, Widget control, {String? description}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SettingsFieldSection(
            title: title,
            description: description,
            child: control,
          ),
        );
    Widget dropdown(Widget control) => InputDecorator(
      decoration: settingsControlDecoration,
      child: DropdownButtonHideUnderline(child: control),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (workMode)
          SwitchListTile(
            title: const Text('计划模式'),
            subtitle: const Text('仅允许明确只读工具；禁止文件写入、命令、设备操作和未知外部工具。'),
            value: policy.planOnly,
            onChanged: (value) => save(policy.copyWith(planOnly: value)),
          ),
        SwitchListTile(
          title: const Text('允许联网检索'),
          subtitle: const Text('由 AI 按需搜索；关闭后不提供网页检索工具。'),
          value: policy.network,
          onChanged: (value) => save(policy.copyWith(network: value)),
        ),
        field(
          '工具权限',
          dropdown(
            DropdownButton<WorkApprovalMode>(
              isExpanded: true,
              isDense: true,
              value: policy.approval,
              onChanged: (v) {
                if (v != null) save(policy.copyWith(approval: v));
              },
              items: [
                for (final mode in WorkApprovalMode.values)
                  DropdownMenuItem(value: mode, child: Text(mode.label)),
              ],
            ),
          ),
          description: switch (policy.approval) {
            WorkApprovalMode.request => '读取自动执行；写入、命令和外部工具执行前请求批准。',
            WorkApprovalMode.assisted => '由评判模型审查操作；不批准或评判失败时交给你决定。',
            WorkApprovalMode.full => '自动执行工具。命令以系统或 SSH 账号权限运行，工作目录不是沙箱。',
          },
        ),
        if (policy.approval == WorkApprovalMode.assisted)
          field(
            '评判模型',
            dropdown(
              DropdownButton<String>(
                isExpanded: true,
                isDense: true,
                value: policy.reviewerModel,
                onChanged: (v) => save(policy.copyWith(reviewerModel: v)),
                items: [
                  for (final model in models)
                    DropdownMenuItem(
                      value: model,
                      child: Text(
                        model.isEmpty ? '当前会话模型' : model,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            description: '按评判模型的服务优先级调用；评判请求也消耗 token。',
          ),
        if (workMode) ...[
          TaskAdvancedOptions(conversationId: conversationId),
          field(
            '工具轮次',
            OutlinedButton.icon(
              onPressed: () =>
                  showWorkRoundSettings(context, ref, conversationId),
              icon: const Icon(Icons.tune, size: 18),
              label: Text(
                '初始 ${policy.toolRounds} 轮 · 每次 +${policy.roundExtension} · ${policy.autoExtendRounds ? 'AI 自动续加' : '手动续加'}',
              ),
            ),
          ),
          const Divider(height: 24),
          field(
            '执行位置',
            dropdown(
              DropdownButton<String>(
                isExpanded: true,
                isDense: true,
                value: policy.sshProfileId,
                items: [
                  const DropdownMenuItem(value: '', child: Text('本机工作区')),
                  for (final profile in research!.profiles)
                    DropdownMenuItem(
                      value: profile.id,
                      child: Text(
                        'SSH · ${profile.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (policy.sshProfileId.isNotEmpty &&
                      !research.profiles.any(
                        (p) => p.id == policy.sshProfileId,
                      ))
                    DropdownMenuItem(
                      value: policy.sshProfileId,
                      child: const Text('SSH 配置已移除'),
                    ),
                ],
                onChanged: (v) => save(policy.copyWith(sshProfileId: v)),
              ),
            ),
          ),
          if (policy.sshProfileId.isNotEmpty)
            field(
              'SSH 工作目录',
              TextFormField(
                key: ValueKey(
                  'remote-root-$conversationId-${policy.sshProfileId}',
                ),
                initialValue: policy.remoteRoot,
                enabled: true,
                decoration: settingsControlDecoration,
                onFieldSubmitted: (v) => save(
                  policy.copyWith(
                    remoteRoot: v.trim().isEmpty ? '.' : v.trim(),
                  ),
                ),
              ),
              description: '使用绝对路径或 .（登录目录），按回车保存。',
            ),
          ListTile(
            leading: const Icon(Icons.terminal),
            title: const Text('科研工作区 · 连接与终端'),
            subtitle: Text(
              research.isConnected
                  ? '已连接：${research.activeProfile?.name}'
                  : 'SSH 执行前，请先连接对应服务器',
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ResearchTerminalPage(),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class ComposerPermissionControl extends ConsumerWidget {
  const ComposerPermissionControl({
    super.key,
    required this.conversationId,
    this.plain = false,
  });
  final String conversationId;
  final bool plain;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy =
        ref.watch(sessionPolicyProvider)[conversationId] ??
        const SessionPolicy();
    return Builder(
      builder: (anchor) => _ComposerPermissionButton(
        key: const ValueKey('composer-permission'),
        plain: plain,
        icon: Icons.shield_outlined,
        label: '${policy.planOnly ? '计划模式 · ' : ''}${policy.approval.label}',
        onPressed: () => showComposerPopover<void>(
          anchor,
          width: 420,
          builder: (menu) => ComposerPopoverFrame(
            title: '工具权限',
            body: ListView(
              shrinkWrap: true,
              children: [
                for (final mode in WorkApprovalMode.values)
                  Card(
                    elevation: 0,
                    color: mode == policy.approval
                        ? Theme.of(menu).colorScheme.primaryContainer
                        : Theme.of(menu).colorScheme.surfaceContainerLow,
                    margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                    child: ListTile(
                      leading: Icon(
                        mode == policy.approval
                            ? Icons.check_circle_outline
                            : Icons.shield_outlined,
                      ),
                      title: Text(mode.label),
                      subtitle: Text(switch (mode) {
                        WorkApprovalMode.request => '读取自动执行；写入、命令和外部工具执行前请求批准。',
                        WorkApprovalMode.assisted => '由评判模型审查；不批准或失败时交给你决定。',
                        WorkApprovalMode.full => '自动执行工具，沿用当前会话的目录与系统权限。',
                      }),
                      onTap: () async {
                        try {
                          await ref
                              .read(sessionPolicyProvider.notifier)
                              .save(
                                conversationId,
                                policy.copyWith(approval: mode),
                              );
                          if (menu.mounted) {
                            Navigator.pop(menu);
                          }
                        } catch (error) {
                          if (context.mounted) {
                            AppToastMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text('$error')));
                          }
                        }
                      },
                    ),
                  ),
                ExpansionTile(
                  title: const Text('评判模型、联网与会话策略'),
                  children: [
                    SessionPolicyControls(
                      conversationId: conversationId,
                      workMode: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerPermissionButton extends StatelessWidget {
  const _ComposerPermissionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.plain,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool plain;
  @override
  Widget build(BuildContext context) {
    if (!plain) {
      return PrototypeChip(label: label, icon: icon, onPressed: onPressed);
    }
    return Tooltip(
      message: '工具权限 · $label',
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: Size(
            44,
            MediaQuery.sizeOf(context).width < 840 ? 44 : 28,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          foregroundColor: PrototypeColors.of(context).muted,
          textStyle: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontSize: 12),
        ),
        icon: Icon(icon, size: 14),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
