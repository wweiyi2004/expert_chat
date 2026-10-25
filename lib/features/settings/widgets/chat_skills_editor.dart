import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';

import 'package:uuid/uuid.dart';

import '../../../data/chat_skill.dart';

class ChatSkillsEditor extends StatelessWidget {
  const ChatSkillsEditor({
    super.key,
    required this.catalog,
    required this.onChanged,
  });

  final ChatSkillCatalog catalog;
  final ValueChanged<ChatSkillCatalog> onChanged;

  void _replace(ChatSkill next) {
    onChanged(
      ChatSkillCatalog([
        for (final skill in catalog.skills)
          if (skill.id == next.id) next else skill,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final skill in catalog.skills)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ChatSkillCard(
              key: ValueKey(skill.id),
              skill: skill,
              onChanged: (next) {
                if (!next.enabled && skill.fallback && skill.enabled) {
                  final otherFallback = catalog.skills.any(
                    (item) =>
                        item.id != skill.id && item.fallback && item.enabled,
                  );
                  if (!otherFallback) {
                    AppToastMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('至少保留一个回退任务类型')),
                    );
                    return;
                  }
                }
                _replace(next);
              },
              onDelete: skill.builtIn
                  ? null
                  : () => onChanged(
                      ChatSkillCatalog([
                        for (final item in catalog.skills)
                          if (item.id != skill.id) item,
                      ]),
                    ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () async {
              final created = await showDialog<ChatSkill>(
                context: context,
                builder: (_) => const _AddChatSkillDialog(),
              );
              if (created == null) return;
              onChanged(ChatSkillCatalog([...catalog.skills, created]));
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加任务类型'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '分类器只根据「何时选用」选择种类；提示词只在选中后注入。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _ChatSkillCard extends StatefulWidget {
  const _ChatSkillCard({
    super.key,
    required this.skill,
    required this.onChanged,
    this.onDelete,
  });

  final ChatSkill skill;
  final ValueChanged<ChatSkill> onChanged;
  final VoidCallback? onDelete;

  @override
  State<_ChatSkillCard> createState() => _ChatSkillCardState();
}

class _ChatSkillCardState extends State<_ChatSkillCard> {
  late final TextEditingController _name;
  late final TextEditingController _when;
  late final TextEditingController _prefix;
  late final TextEditingController _prompt;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.skill.name);
    _when = TextEditingController(text: widget.skill.when);
    _prefix = TextEditingController(text: widget.skill.prefix);
    _prompt = TextEditingController(text: widget.skill.prompt);
  }

  @override
  void dispose() {
    _name.dispose();
    _when.dispose();
    _prefix.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _emit({bool? enabled}) {
    widget.onChanged(
      widget.skill.copyWith(
        name: _name.text,
        when: _when.text,
        prefix: _prefix.text,
        prompt: _prompt.text,
        enabled: enabled ?? widget.skill.enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final skill = widget.skill;
    return Card(
      key: ValueKey('chat-skill-card-${skill.id}'),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        dense: false,
        minTileHeight: 0,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              skill.name.isEmpty ? '未命名' : skill.name,
              key: ValueKey('chat-skill-title-${skill.id}'),
            ),
            const SizedBox(height: 4),
            Text(
              skill.when.isEmpty ? skill.prefix : skill.when,
              key: ValueKey('chat-skill-description-${skill.id}'),
              style:
                  ListTileTheme.of(context).subtitleTextStyle ??
                  Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch.adaptive(
              key: ValueKey('chat-skill-enabled-${skill.id}'),
              value: skill.enabled,
              onChanged: (value) => _emit(enabled: value),
            ),
            if (widget.onDelete != null)
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline),
                onPressed: widget.onDelete,
              ),
            const Icon(Icons.expand_more),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _when,
            decoration: const InputDecoration(labelText: '何时选用'),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _prefix,
            decoration: const InputDecoration(labelText: '前缀'),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _prompt,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '提示词',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _emit(),
          ),
        ],
      ),
    );
  }
}

class _AddChatSkillDialog extends StatefulWidget {
  const _AddChatSkillDialog();

  @override
  State<_AddChatSkillDialog> createState() => _AddChatSkillDialogState();
}

class _AddChatSkillDialogState extends State<_AddChatSkillDialog> {
  final _name = TextEditingController();
  final _when = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _when.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final when = _when.text.trim();
    if (name.isEmpty || when.isEmpty) return;
    Navigator.of(context).pop(
      ChatSkill(
        id: 'custom_${const Uuid().v4()}',
        name: name,
        when: when,
        prompt: '',
        prefix: '/$name',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加任务类型'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: '名称'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _when,
            decoration: const InputDecoration(labelText: '何时选用'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty || _when.text.trim().isEmpty
              ? null
              : _submit,
          child: const Text('添加'),
        ),
      ],
    );
  }
}
