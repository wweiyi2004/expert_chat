import 'package:flutter/material.dart';
import 'composer_popover.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/conversation_model_choice.dart';
import '../../../state/settings_controller.dart';
import '../../../state/model_service_routing.dart';

class ComposerModelPicker extends ConsumerWidget {
  const ComposerModelPicker({
    super.key,
    required this.conversationId,
    required this.enabled,
  });
  final String conversationId;
  final bool enabled;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider).value;
    if (settings == null) return const SizedBox.shrink();
    final choice =
        ref.watch(conversationModelChoiceProvider)[conversationId] ??
        settings.model;
    final label = choice == autoModelChoice ? 'Auto' : choice;
    return Tooltip(
      message: choice == autoModelChoice
          ? '按图片、工具和思考能力自动选择模型，优先当前默认模型'
          : '当前会话模型：$label',
      child: Builder(
        builder: (anchor) => TextButton(
          onPressed: !enabled
              ? null
              : () async {
                  final selected = await showComposerPopover<String>(
                    anchor,
                    builder: (_) => _ModelChoices(
                      models: serviceModelCatalog(settings.profiles),
                      selected: choice,
                    ),
                  );
                  if (selected == null || !context.mounted) return;
                  try {
                    if (selected != autoModelChoice) {
                      final services = servicesForModel(
                        selected,
                        settings.profiles,
                        ref.read(modelServiceRoutingProvider),
                      );
                      if (services.isNotEmpty) {
                        await ref
                            .read(settingsControllerProvider.notifier)
                            .selectProfile(services.first.id);
                        await ref
                            .read(settingsControllerProvider.notifier)
                            .apply(selectedModel: selected);
                      }
                    }
                    await ref
                        .read(conversationModelChoiceProvider.notifier)
                        .select(conversationId, selected);
                  } catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('$error')));
                    }
                  }
                },
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: 9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome_outlined, size: 15),
              const SizedBox(width: 5),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const Icon(Icons.expand_more, size: 15),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelChoices extends StatefulWidget {
  const _ModelChoices({required this.models, required this.selected});
  final List<String> models;
  final String selected;
  @override
  State<_ModelChoices> createState() => _ModelChoicesState();
}

class _ModelChoicesState extends State<_ModelChoices> {
  String _query = '';
  @override
  Widget build(BuildContext context) => ComposerPopoverFrame(
    title: '选择模型',
    body: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 19),
              hintText: '搜索模型',
            ),
            onChanged: (q) => setState(() => _query = q),
          ),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.auto_awesome_outlined),
          title: const Text('Auto'),
          subtitle: const Text('按当前任务需要的能力选择'),
          selected: widget.selected == autoModelChoice,
          onTap: () => Navigator.pop(context, autoModelChoice),
        ),
        const Divider(height: 1),
        for (final model in widget.models.where(
          (m) => m.toLowerCase().contains(_query.toLowerCase()),
        ))
          ListTile(
            dense: true,
            title: Text(model),
            selected: model == widget.selected,
            trailing: model == widget.selected
                ? const Icon(Icons.check, size: 18)
                : null,
            onTap: () => Navigator.pop(context, model),
          ),
      ],
    ),
  );
}
