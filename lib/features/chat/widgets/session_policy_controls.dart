import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/session_policy.dart';
import '../../../state/model_service_routing.dart';
import '../../../state/settings_controller.dart';
import '../../../state/research_terminal_controller.dart';
import '../../research/research_terminal_page.dart';
import 'work_round_controls.dart';
import 'settings_field_section.dart';

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
        if (context.mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
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
  const ComposerPermissionControl({super.key, required this.conversationId});
  final String conversationId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy =
        ref.watch(sessionPolicyProvider)[conversationId] ??
        const SessionPolicy();
    return MenuAnchor(
      menuChildren: [
        for (final mode in WorkApprovalMode.values)
          MenuItemButton(
            leadingIcon: Icon(
              mode == policy.approval ? Icons.check : Icons.shield_outlined,
              size: 17,
            ),
            onPressed: () async {
              try {
                await ref
                    .read(sessionPolicyProvider.notifier)
                    .save(conversationId, policy.copyWith(approval: mode));
              } catch (error) {
                if (context.mounted)
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('$error')));
              }
            },
            child: Text(mode.label),
          ),
      ],
      builder: (context, menu, _) => LayoutBuilder(
        builder: (context, constraints) {
          void toggle() => menu.isOpen ? menu.close() : menu.open();
          if (constraints.maxWidth < 100) {
            return IconButton(
              tooltip: '工具权限 · ${policy.approval.label}',
              onPressed: toggle,
              icon: const Icon(Icons.shield_outlined, size: 17),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(32),
                maximumSize: const Size.square(32),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            );
          }
          return TextButton.icon(
            onPressed: toggle,
            icon: const Icon(Icons.shield_outlined, size: 15),
            label: Text(
              policy.approval.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        },
      ),
    );
  }
}
