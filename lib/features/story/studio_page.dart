import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'character_library_page.dart';
import 'world_info_page.dart';

/// Unified hub: character cards + world info in one place.
class StudioPage extends ConsumerStatefulWidget {
  const StudioPage({
    super.key,
    this.initialTab = 0,
    this.pickCharacter = false,
  });

  final int initialTab;

  /// When true, character tab is in "start chat" mode and pops after pick.
  final bool pickCharacter;

  @override
  ConsumerState<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends ConsumerState<StudioPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1),
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Pick-character is a pushed route (show back). Shell tab hides leading.
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pickCharacter ? '选择角色开聊' : '创作'),
        automaticallyImplyLeading: widget.pickCharacter,
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.person_outline), text: '角色'),
            Tab(icon: Icon(Icons.public_outlined), text: '世界书'),
          ],
        ),
      ),
      floatingActionButton: ListenableBuilder(
        listenable: _tabs,
        builder: (context, _) {
          final onCharacters = _tabs.index == 0;
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
        controller: _tabs,
        children: [
          CharacterLibraryBody(pickForChat: widget.pickCharacter),
          const WorldInfoBody(),
        ],
      ),
    );
  }
}
