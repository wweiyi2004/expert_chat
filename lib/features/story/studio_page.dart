import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mode_style.dart';
import '../../data/story_models.dart';
import '../../state/character_controller.dart';
import '../../state/world_info_controller.dart';
import 'character_library_page.dart';
import 'director_story_setup_page.dart';
import 'ensemble_setup_page.dart';
import 'studio_asset_actions.dart';
import 'world_info_page.dart';

/// Creation hub: start paths + character / world-info libraries.
///
/// Tabs: 0 开始 · 1 角色 · 2 世界书
/// When [pickCharacter] is true, only the character picker is shown (legacy
/// route used when a flow needs "pick a card and start chat").
class StudioPage extends ConsumerStatefulWidget {
  const StudioPage({
    super.key,
    this.initialTab = 0,
    this.pickCharacter = false,
  });

  /// 0 开始 · 1 角色 · 2 世界书（[pickCharacter] 时忽略）。
  final int initialTab;

  /// When true, character tab is in "start chat" mode and pops after pick.
  final bool pickCharacter;

  @override
  ConsumerState<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends ConsumerState<StudioPage>
    with SingleTickerProviderStateMixin {
  TabController? _tabs;

  @override
  void initState() {
    super.initState();
    if (!widget.pickCharacter) {
      _tabs = TabController(
        length: 3,
        vsync: this,
        initialIndex: widget.initialTab.clamp(0, 2),
      );
    }
  }

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  void _goCharactersTab() {
    _tabs?.animateTo(1);
  }

  void _goWorldTab() {
    _tabs?.animateTo(2);
  }

  Future<void> _openDirector() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DirectorStorySetupPage()),
    );
  }

  Future<void> _openEnsemble() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const EnsembleSetupPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pickCharacter) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('选择角色开聊'),
          automaticallyImplyLeading: true,
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => editCharacterCard(context, ref, null),
          tooltip: '新建角色',
          child: const Icon(Icons.add),
        ),
        body: const CharacterLibraryBody(pickForChat: true),
      );
    }

    final tabs = _tabs!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('创作'),
        automaticallyImplyLeading: false,
        actions: [
          ListenableBuilder(
            listenable: tabs,
            builder: (context, _) {
              if (tabs.index == 0) return const SizedBox.shrink();
              final onCharacters = tabs.index == 1;
              return PopupMenuButton<String>(
                tooltip: '导入 / 导出',
                onSelected: (v) async {
                  if (onCharacters) {
                    if (v == 'import') {
                      await importCharactersAction(context, ref);
                    } else if (v == 'export') {
                      await exportAllCharactersAction(context, ref);
                    }
                  } else {
                    if (v == 'import') {
                      await importWorldInfoAction(context, ref);
                    } else if (v == 'export') {
                      await exportAllWorldInfoAction(context, ref);
                    }
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'import', child: Text('导入 JSON')),
                  PopupMenuItem(value: 'export', child: Text('导出全部 JSON')),
                ],
              );
            },
          ),
        ],
        bottom: TabBar(
          controller: tabs,
          tabs: const [
            Tab(icon: Icon(Icons.play_circle_outline), text: '开始'),
            Tab(icon: Icon(Icons.person_outline), text: '角色'),
            Tab(icon: Icon(Icons.public_outlined), text: '世界书'),
          ],
        ),
      ),
      floatingActionButton: ListenableBuilder(
        listenable: tabs,
        builder: (context, _) {
          if (tabs.index == 0) return const SizedBox.shrink();
          final onCharacters = tabs.index == 1;
          return FloatingActionButton(
            onPressed: () {
              if (onCharacters) {
                editCharacterCard(context, ref, null);
              } else {
                editWorldInfoEntry(context, ref, null);
              }
            },
            tooltip: onCharacters ? '新建角色' : '新建条目',
            child: const Icon(Icons.add),
          );
        },
      ),
      body: TabBarView(
        controller: tabs,
        children: [
          _StudioStartBody(
            onDirector: _openDirector,
            onEnsemble: _openEnsemble,
            onPickCharacter: _goCharactersTab,
            onOpenWorld: _goWorldTab,
          ),
          const CharacterLibraryBody(pickForChat: false),
          const WorldInfoBody(),
        ],
      ),
    );
  }
}

/// Landing content for the 开始 tab: primary creation entry points.
class _StudioStartBody extends ConsumerWidget {
  const _StudioStartBody({
    required this.onDirector,
    required this.onEnsemble,
    required this.onPickCharacter,
    required this.onOpenWorld,
  });

  final VoidCallback onDirector;
  final VoidCallback onEnsemble;
  final VoidCallback onPickCharacter;
  final VoidCallback onOpenWorld;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final cardCount = ref.watch(characterCardsProvider).value?.length ?? 0;
    final worldCount = ref.watch(worldInfoProvider).value?.length ?? 0;

    return ListView(
      key: const ValueKey('studio-start-body'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('开始创作', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          '从一条路径开聊或开写；素材在「角色」「世界书」里管理。',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        _StartPathCard(
          key: const ValueKey('studio-start-director'),
          color: ModeStyle.story,
          icon: ModeStyle.icon(ConversationMode.story, outlined: false),
          title: '导演故事',
          subtitle: '只需情节种子。AI 自动选角、写大纲，并扮演全部角色；你当导演。',
          badge: '推荐新手',
          onTap: onDirector,
        ),
        const SizedBox(height: 10),
        _StartPathCard(
          key: const ValueKey('studio-start-ensemble'),
          color: ModeStyle.ensemble,
          icon: ModeStyle.icon(ConversationMode.ensemble, outlined: false),
          title: '角色大乱斗',
          subtitle: '选 2 名以上角色同台轮流发言，适合群戏与碰撞。',
          onTap: onEnsemble,
        ),
        const SizedBox(height: 10),
        _StartPathCard(
          key: const ValueKey('studio-start-pick-character'),
          color: ModeStyle.chat,
          icon: Icons.person_search_outlined,
          title: '选角色开聊',
          subtitle: cardCount == 0
              ? '还没有角色卡。可先建一张，或用上方「导演故事」免卡开写。'
              : '从角色库挑一张卡，带开场白进入故事会话（已有 $cardCount 张）。',
          onTap: onPickCharacter,
        ),
        const SizedBox(height: 28),
        Text('我的素材', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _AssetSummaryTile(
                key: const ValueKey('studio-asset-characters'),
                icon: Icons.person_outline,
                label: '角色',
                count: cardCount,
                onTap: onPickCharacter,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _AssetSummaryTile(
                key: const ValueKey('studio-asset-world'),
                icon: Icons.public_outlined,
                label: '世界书',
                count: worldCount,
                onTap: onOpenWorld,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StartPathCard extends StatelessWidget {
  const _StartPathCard({
    super.key,
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withValues(alpha: 0.28)),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (badge != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              badge!,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: color,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetSummaryTile extends StatelessWidget {
  const _AssetSummaryTile({
    super.key,
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      count == 0 ? '暂无' : '$count 项',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
