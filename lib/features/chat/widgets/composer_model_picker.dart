import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import '../../../core/prototype_widgets.dart';
import '../../../data/provider_profile.dart';
import 'composer_popover.dart';
import '../../../domain/llm/llm_provider.dart';
import 'reasoning_effort_control.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/conversation_model_choice.dart';
import '../../../state/settings_controller.dart';
import '../../../state/model_service_routing.dart';
import '../../../state/model_route_groups.dart';
import '../../../state/model_context.dart';

class ComposerModelPicker extends ConsumerWidget {
  const ComposerModelPicker({
    super.key,
    required this.conversationId,
    required this.enabled,
    this.thinking = false,
    this.effort = ReasoningEffort.high,
    this.supportsEffort = false,
    this.onToggleThinking,
    this.onEffortChanged,
  });
  final String conversationId;
  final bool enabled;
  final bool thinking, supportsEffort;
  final ReasoningEffort effort;
  final VoidCallback? onToggleThinking;
  final ValueChanged<ReasoningEffort>? onEffortChanged;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider).value;
    if (settings == null) return const SizedBox.shrink();
    final choice =
        ref.watch(conversationModelChoiceProvider)[conversationId] ??
        settings.model;
    final groups = ref.watch(modelRouteGroupsProvider).groups;
    final source = parseModelSourceChoice(choice);
    final selectedGroup = groups
        .where((g) => '$modelGroupPrefix${g.id}' == choice)
        .firstOrNull;
    final selectedModel =
        source?.model ??
        selectedGroup?.models.firstOrNull ??
        (choice == autoModelChoice ? settings.model : choice);
    final selectedProfile = source == null
        ? settings.active
        : settings.profiles.where((p) => p.id == source.profile).firstOrNull;
    final selectedConfig = applyReportedModelCapabilities(
      settings,
      settings.config.copyWith(
        model: selectedModel,
        profileId: selectedProfile?.id,
        baseUrl: selectedProfile?.baseUrl,
        apiFormat: selectedProfile?.apiFormat,
      ),
    );
    final label = source != null
        ? '${source.model} · ${settings.profiles.where((p) => p.id == source.profile).firstOrNull?.name ?? "已删除来源"}'
        : choice == autoModelChoice
        ? 'Auto'
        : choice.startsWith(modelGroupPrefix)
        ? groups
                  .where((g) => '$modelGroupPrefix${g.id}' == choice)
                  .firstOrNull
                  ?.name ??
              '已删除路由组'
        : choice;
    final effectiveThinking =
        thinking ||
        (selectedConfig.capabilities.isReasoner &&
            !selectedConfig.capabilities.reasoningCanBeDisabled &&
            !selectedConfig.capabilities.sendThinkingField);
    final thoughtLabel =
        '思考：${effectiveThinking ? ((selectedConfig.capabilities.supportsReasoningEffort || supportsEffort) ? effort.label : '开启') : '关闭'}';
    final hasThinkingControl = onToggleThinking != null;
    return Tooltip(
      message: choice == autoModelChoice
          ? '按图片、工具和思考能力自动选择模型，优先当前默认模型'
          : hasThinkingControl
          ? '当前会话模型：$label · $thoughtLabel'
          : '当前会话模型：$label',
      child: Builder(
        builder: (anchor) => LayoutBuilder(
          builder: (context, constraints) => PrototypeChip(
            key: const ValueKey('composer-model-thinking'),
            onPressed: !enabled
                ? null
                : () async {
                    var currentThinking = effectiveThinking;
                    var currentEffort = effort;
                    final selected = await showComposerPopover<String>(
                      anchor,
                      builder: (_) => StatefulBuilder(
                        builder: (context, setMenuState) => _ModelChoices(
                          profiles: settings.profiles,
                          selected: choice,
                          groups: groups,
                          thinkingControl: onToggleThinking == null
                              ? null
                              : ReasoningEffortSlider(
                                  config: selectedConfig,
                                  thinking: currentThinking,
                                  effort: currentEffort,
                                  supportsEffort:
                                      selectedConfig
                                          .capabilities
                                          .supportsReasoningEffort ||
                                      supportsEffort,
                                  onToggle: () {
                                    onToggleThinking!();
                                    setMenuState(
                                      () => currentThinking = !currentThinking,
                                    );
                                  },
                                  onChanged: (value) {
                                    onEffortChanged?.call(value);
                                    setMenuState(() => currentEffort = value);
                                  },
                                ),
                        ),
                      ),
                    );
                    if (selected == null || !context.mounted) return;
                    try {
                      if (selected != autoModelChoice &&
                          !selected.startsWith(modelGroupPrefix)) {
                        final pinned = parseModelSourceChoice(selected);
                        final services = servicesForModel(
                          pinned?.model ?? selected,
                          pinned == null
                              ? settings.profiles
                              : settings.profiles
                                    .where((p) => p.id == pinned.profile)
                                    .toList(),
                          ref.read(modelServiceRoutingProvider),
                        );
                        if (services.isNotEmpty) {
                          await ref
                              .read(settingsControllerProvider.notifier)
                              .selectProfile(services.first.id);
                          await ref
                              .read(settingsControllerProvider.notifier)
                              .apply(selectedModel: pinned?.model ?? selected);
                        }
                      }
                      await ref
                          .read(conversationModelChoiceProvider.notifier)
                          .select(conversationId, selected);
                    } catch (error) {
                      if (context.mounted) {
                        AppToastMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('$error')));
                      }
                    }
                  },
            label: !hasThinkingControl
                ? label
                : _fitModelLabel(
                    context,
                    label,
                    thoughtLabel,
                    constraints.maxWidth,
                  ),
            icon: Icons.auto_awesome_outlined,
            tooltip: hasThinkingControl ? '$label · $thoughtLabel' : label,
          ),
        ),
      ),
    );
  }
}

String _fitModelLabel(
  BuildContext context,
  String model,
  String thought,
  double width,
) {
  if (!width.isFinite) return '$model · $thought';
  final available = (width - 41).clamp(0.0, double.infinity);
  double measured(String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontSize: 12,
          height: 1.3,
          fontWeight: FontWeight.w400,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final result = painter.width;
    painter.dispose();
    return result;
  }

  if (measured('$model · $thought') <= available) return '$model · $thought';
  final chars = model.characters.toList();
  var low = 0, high = chars.length;
  while (low < high) {
    final middle = (low + high + 1) ~/ 2;
    if (measured('${chars.take(middle).join()}… · $thought') <= available) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return low == 0 ? thought : '${chars.take(low).join()}… · $thought';
}

class _ModelChoices extends StatefulWidget {
  const _ModelChoices({
    required this.profiles,
    required this.selected,
    required this.groups,
    this.thinkingControl,
  });
  final List<ProviderProfile> profiles;
  final String selected;
  final List<ModelRouteGroup> groups;
  final Widget? thinkingControl;
  @override
  State<_ModelChoices> createState() => _ModelChoicesState();
}

String _sourceHost(ProviderProfile profile) =>
    Uri.tryParse(profile.baseUrl)?.host ?? '';
String _sourceName(ProviderProfile profile) =>
    profile.name.trim().isEmpty ? '未命名服务' : profile.name;

class _ModelChoicesState extends State<_ModelChoices> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final c = PrototypeColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sourceTints = [scheme.primary, scheme.tertiary, scheme.secondary];
    final sourceGroups = <(ProviderProfile, List<String>)>[];
    for (final profile in widget.profiles) {
      final sourceMatches =
          _sourceName(profile).toLowerCase().contains(query) ||
          _sourceHost(profile).toLowerCase().contains(query);
      final models = serviceModelCatalog([profile])
          .where(
            (model) => sourceMatches || model.toLowerCase().contains(query),
          )
          .toList();
      if (models.isNotEmpty) sourceGroups.add((profile, models));
    }
    final routeGroups = widget.groups
        .where(
          (group) =>
              group.name.toLowerCase().contains(query) ||
              group.models.any((model) => model.toLowerCase().contains(query)),
        )
        .toList();
    Widget heading(String title, {String? subtitle, Key? key}) => Container(
      key: key,
      color: c.panel,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: c.ink,
            ),
          ),
          if (subtitle != null && subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontSize: 11.5, color: c.muted),
            ),
          ],
        ],
      ),
    );
    return ComposerPopoverFrame(
      title: widget.thinkingControl == null ? '模型' : '模型与思考',
      body: ListView(
        key: const ValueKey('composer-model-source-list'),
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          if (widget.thinkingControl != null) widget.thinkingControl!,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: TextField(
              key: const ValueKey('composer-model-search'),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '搜索模型或来源',
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '点选来源内模型会固定该来源；Auto 和用户路由组按各自策略选择与故障转移。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontSize: 11.5, color: c.muted),
            ),
          ),
          heading('自动选择'),
          _ModelChoiceRow(
            title: 'Auto',
            subtitle: '按当前任务需要的能力选择',
            selected: widget.selected == autoModelChoice,
            icon: Icons.auto_awesome_outlined,
            onTap: () => Navigator.pop(context, autoModelChoice),
          ),
          if (routeGroups.isNotEmpty) ...[
            heading('用户路由组'),
            for (final group in routeGroups)
              _ModelChoiceRow(
                key: ValueKey('model-route-${group.id}'),
                title: group.name,
                subtitle: group.models.join(' → '),
                selected: widget.selected == '$modelGroupPrefix${group.id}',
                onTap: () =>
                    Navigator.pop(context, '$modelGroupPrefix${group.id}'),
              ),
          ],
          for (final entry in sourceGroups)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Material(
                color: Color.alphaBlend(
                  sourceTints[widget.profiles.indexOf(entry.$1) %
                          sourceTints.length]
                      .withValues(alpha: .10),
                  scheme.surfaceContainer,
                ),
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  key: ValueKey('model-source-${entry.$1.id}'),
                  initiallyExpanded: true,
                  title: Text(
                    _sourceName(entry.$1),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${_sourceHost(entry.$1)} · ${entry.$2.length} 个模型',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  children: [
                    for (final model in entry.$2)
                      _ModelChoiceRow(
                        key: ValueKey('model-option-${entry.$1.id}-$model'),
                        title: model,
                        subtitle: '固定来源：${_sourceName(entry.$1)}',
                        selected:
                            widget.selected ==
                            modelSourceChoice(entry.$1.id, model),
                        onTap: () => Navigator.pop(
                          context,
                          modelSourceChoice(entry.$1.id, model),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (sourceGroups.isEmpty && routeGroups.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '没有匹配的模型或来源',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: c.muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _ModelChoiceRow extends StatelessWidget {
  const _ModelChoiceRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.icon,
  });
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? c.panel : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.sizeOf(context).width < 840 ? 44 : 36,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: c.muted),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          softWrap: true,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontSize: 13, color: c.ink),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            softWrap: true,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontSize: 11.5, color: c.muted),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check, size: 16, color: c.ink),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
