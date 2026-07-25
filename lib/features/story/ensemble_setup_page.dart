import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/story_models.dart';
import '../../state/character_controller.dart';
import '../../state/chat_controller.dart';

/// Pick 2+ characters, set a venue, start multi-character dialogue.
class EnsembleSetupPage extends ConsumerStatefulWidget {
  const EnsembleSetupPage({super.key});

  @override
  ConsumerState<EnsembleSetupPage> createState() => _EnsembleSetupPageState();
}

class _EnsembleSetupPageState extends ConsumerState<EnsembleSetupPage> {
  final _venue = TextEditingController(
    text: '废弃游乐场中央广场，霓虹闪烁，夜风很冷',
  );
  final _note = TextEditingController();
  final _selected = <String>{};
  var _starting = false;

  @override
  void dispose() {
    _venue.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _start(List<CharacterCard> all) async {
    final cast = [for (final c in all) if (_selected.contains(c.id)) c];
    if (cast.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请至少选择 2 名角色'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _starting = true);
    try {
      await ref
          .read(chatControllerProvider.notifier)
          .newEnsembleConversation(
            cast: cast,
            venue: _venue.text,
            authorNote: _note.text,
          );
      if (mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(characterCardsProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('角色大乱斗')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (cards) {
          if (cards.length < 2) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.groups_outlined, size: 48, color: scheme.outline),
                    const SizedBox(height: 12),
                    const Text('至少需要 2 张角色卡'),
                    const SizedBox(height: 8),
                    const Text('请先到创作中心创建角色'),
                  ],
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
            children: [
              Text(
                '把多名角色丢进同一场景，轮流发言对谈。你可随时插入导演指令或用户发言。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _venue,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '场地 / 情境',
                  hintText: '他们在哪里、什么氛围？',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '导演指令（可选）',
                  hintText: '例如：火药味、禁止 OOC、每人一句话…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('选择角色', style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  Text(
                    '已选 ${_selected.length}',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final c in cards)
                CheckboxListTile(
                  value: _selected.contains(c.id),
                  title: Text(c.name),
                  subtitle: Text(
                    c.personality.isNotEmpty
                        ? c.personality
                        : (c.description.isEmpty ? '无简介' : c.description),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  secondary: CircleAvatar(
                    child: Text(
                      c.name.isEmpty
                          ? '?'
                          : String.fromCharCode(c.name.runes.first),
                    ),
                  ),
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selected.add(c.id);
                      } else {
                        _selected.remove(c.id);
                      }
                    });
                  },
                ),
            ],
          );
        },
      ),
      bottomNavigationBar: async.maybeWhen(
        data: (cards) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              onPressed: _starting ? null : () => _start(cards),
              icon: _starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sports_kabaddi),
              label: Text(_starting ? '创建中…' : '开打'),
            ),
          ),
        ),
        orElse: () => const SizedBox.shrink(),
      ),
    );
  }
}
