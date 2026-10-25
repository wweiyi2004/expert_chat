import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../data/subagent_role.dart';
import '../../../state/settings_controller.dart';
import '../../../state/work_agents.dart';
import '../../../state/model_service_routing.dart';
import 'role_evolution_panel.dart';

class SubagentRolesEditor extends ConsumerWidget {
  const SubagentRolesEditor({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider).value;
    if (settings == null) return const SizedBox.shrink();
    final roles = settings.effectiveSubagentRoles;
    final pool = ref.watch(workAgentModelPoolProvider);
    final poolModels = pool?.map((m) => m.model).toList() ?? [settings.model];
    final routingModels = {
      ...serviceModelCatalog(settings.profiles),
      settings.model,
      if (settings.subagentRouterModel.isNotEmpty) settings.subagentRouterModel,
    }.toList()..sort();
    Future<void> replace(SubagentRole next) {
      final current = ref
          .read(settingsControllerProvider)
          .requireValue
          .effectiveSubagentRoles;
      return ref.read(settingsControllerProvider.notifier).setSubagentRoles([
        for (final role in current)
          if (role.id == next.id) next else role,
      ]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('子代理角色库', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Text(
          '派工时由模型按“何时选用”自动分配角色，再使用该角色的系统指令和模型执行。孙代理同样按任务分配。角色指令修改在下一完整工具轮生效，模型绑定用于新任务。',
        ),
        const SizedBox(height: 12),
        const RoleEvolutionPanel(),
        const SizedBox(height: 16),
        KeyedSubtree(
          key: const ValueKey('role-router-field'),
          child: DropdownButtonFormField<String>(
            key: ValueKey('role-router-${settings.subagentRouterModel}'),
            initialValue: settings.subagentRouterModel,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '角色分配模型',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('跟随当前主模型')),
              for (final model in routingModels.where((m) => m.isNotEmpty))
                DropdownMenuItem(
                  value: model,
                  child: Text(model, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) async {
              if (value == null) return;
              try {
                await ref
                    .read(settingsControllerProvider.notifier)
                    .setSubagentRouterModel(value);
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
        const SizedBox(height: 12),
        for (final role in roles)
          _RoleCard(
            key: ValueKey(role.id),
            role: role,
            models: poolModels,
            onSave: replace,
            onDelete: () async {
              final current = ref
                  .read(settingsControllerProvider)
                  .requireValue
                  .effectiveSubagentRoles;
              await ref
                  .read(settingsControllerProvider.notifier)
                  .setSubagentRoles(
                    current.where((r) => r.id != role.id).toList(),
                  );
            },
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加子代理角色'),
            onPressed: roles.length >= 40
                ? null
                : () async {
                    try {
                      await ref
                          .read(settingsControllerProvider.notifier)
                          .setSubagentRoles([
                            ...ref
                                .read(settingsControllerProvider)
                                .requireValue
                                .effectiveSubagentRoles,
                            SubagentRole(
                              id: const Uuid().v4(),
                              name: '新角色',
                              when: '',
                              instructions: '',
                              enabled: false,
                            ),
                          ]);
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
        const SizedBox(height: 6),
        const Text(
          '角色绑定模型只能从子代理模型池选择；“自动选择”由分配模型在池内决定。旧的子代理提示词保留在“通用执行”角色中。',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

class _RoleCard extends StatefulWidget {
  const _RoleCard({
    super.key,
    required this.role,
    required this.models,
    required this.onSave,
    required this.onDelete,
  });
  final SubagentRole role;
  final List<String> models;
  final Future<void> Function(SubagentRole) onSave;
  final Future<void> Function() onDelete;
  @override
  State<_RoleCard> createState() => _RoleCardState();
}

class _RoleCardState extends State<_RoleCard> {
  late final _name = TextEditingController(text: widget.role.name);
  late final _when = TextEditingController(text: widget.role.when);
  late final _instructions = TextEditingController(
    text: widget.role.instructions,
  );
  late bool _enabled = widget.role.enabled;
  late String _model = widget.role.model;
  bool _saving = false;
  String? _error;
  bool get _dirty =>
      _name.text.trim() != widget.role.name ||
      _when.text.trim() != widget.role.when ||
      _instructions.text.trim() != widget.role.instructions ||
      _model != widget.role.model ||
      _enabled != widget.role.enabled;
  @override
  void dispose() {
    _name.dispose();
    _when.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        widget.role.copyWith(
          name: _name.text.trim(),
          when: _when.text.trim(),
          instructions: _instructions.text.trim(),
          model: _model,
          enabled: _enabled,
        ),
      );
    } catch (error) {
      if (mounted) _error = '$error';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      key: ValueKey('subagent-role-header-${widget.role.id}'),
      dense: false,
      minTileHeight: 0,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      initiallyExpanded: widget.role.name == '新角色',
      leading: Icon(
        _enabled ? Icons.hub_outlined : Icons.pause_circle_outline,
        size: 21,
      ),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.role.name}${_dirty ? ' · 未保存' : ''}',
            key: ValueKey('subagent-role-title-${widget.role.id}'),
          ),
          const SizedBox(height: 4),
          Text(
            widget.role.when.isEmpty ? '填写适用任务和指令' : widget.role.when,
            key: ValueKey('subagent-role-description-${widget.role.id}'),
            style:
                ListTileTheme.of(context).subtitleTextStyle ??
                Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        if (widget.role.source.isNotEmpty)
          SelectableText(
            'v${widget.role.version} · ${widget.role.source}\n所需工具：${widget.role.requiredTools.join(', ')}\n验收：${widget.role.validation.isEmpty ? '用户已修改，旧验收失效' : widget.role.validation}',
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用此角色'),
          value: _enabled,
          onChanged: _saving ? null : (v) => setState(() => _enabled = v),
        ),
        TextField(
          controller: _name,
          readOnly: _saving,
          maxLength: 60,
          decoration: const InputDecoration(labelText: '名称'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _when,
          readOnly: _saving,
          minLines: 2,
          maxLines: 3,
          maxLength: 600,
          decoration: const InputDecoration(
            labelText: '何时选用',
            alignLabelWithHint: true,
            hintText: '例如：检查实现缺陷、审计安全性、给出代码评审意见',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _model,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '执行模型',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('自动选择（限子代理模型池）')),
            for (final model in {
              ...widget.models,
              if (_model.isNotEmpty) _model,
            })
              DropdownMenuItem(
                value: model,
                child: Text(
                  '$model${widget.models.contains(model) ? '' : '（不在模型池）'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _saving
              ? null
              : (value) {
                  if (value != null) setState(() => _model = value);
                },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _instructions,
          readOnly: _saving,
          minLines: 5,
          maxLines: 12,
          maxLength: 24000,
          decoration: const InputDecoration(
            labelText: '角色系统指令',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 6,
          children: [
            if (SubagentRole.defaults().any((r) => r.id == widget.role.id))
              TextButton(
                onPressed: _saving
                    ? null
                    : () {
                        final original = SubagentRole.defaults().firstWhere(
                          (r) => r.id == widget.role.id,
                        );
                        setState(() {
                          _instructions.text = original.instructions;
                          _error = null;
                        });
                      },
                child: const Text('载入默认指令'),
              ),
            TextButton(
              onPressed: _saving
                  ? null
                  : () async {
                      try {
                        await widget.onDelete();
                      } catch (e) {
                        if (mounted) setState(() => _error = '$e');
                      }
                    },
              child: const Text('删除角色'),
            ),
            FilledButton(
              onPressed: _saving || !_dirty || _name.text.trim().isEmpty
                  ? null
                  : _save,
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ],
    ),
  );
}
