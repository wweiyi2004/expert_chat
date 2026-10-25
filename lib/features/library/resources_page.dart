import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../core/prototype_widgets.dart';
import '../../data/db/app_database.dart' show Project;
import '../../state/chat_controller.dart';
import '../shell/shell_tab.dart';
import '../../state/settings_controller.dart';
import '../../state/study_controller.dart';
import '../../data/study_models.dart';
import '../../domain/study/srs_scheduler.dart';
import '../chat/widgets/library_picker_sheet.dart';
import '../projects/projects_page.dart';
import '../study/review_session_page.dart';
import '../study/tutor_setup_page.dart';
import '../study/study_hub_page.dart';
import '../story/director_story_setup_page.dart';
import '../story/character_library_page.dart';
import '../story/world_info_page.dart';
import '../story/ensemble_setup_page.dart';
import '../story/studio_page.dart';
import 'generation_history_page.dart';

final _resourceSetsProvider =
    FutureProvider.autoDispose<
      ({List<Project> projects, Map<String, int> counts})
    >((ref) async {
      final repository = ref.watch(projectRepositoryProvider);
      final projects = await repository.list();
      final counts = await repository.fileCounts();
      return (projects: projects, counts: counts);
    });

class ResourcesPage extends ConsumerStatefulWidget {
  const ResourcesPage({
    super.key,
    this.onOpenNavigation,
    this.shellHeader = false,
  });
  final VoidCallback? onOpenNavigation;
  final bool shellHeader;
  @override
  ConsumerState<ResourcesPage> createState() => _ResourcesPageState();
}

class _ResourcesPageState extends ConsumerState<ResourcesPage> {
  String _tab = 'sets';
  Future<void> _manage({String? id, bool create = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ProjectsPage(initialProjectId: id, createOnOpen: create),
      ),
    );
    if (!mounted) return;
    ref.invalidate(projectRepositoryProvider);
    ref.invalidate(_resourceSetsProvider);
  }

  void _useSet(String id) {
    ref
        .read(chatControllerProvider.notifier)
        .newConversation(projectId: id, workMode: false, forceNew: true);
    ref.read(shellTabProvider.notifier).set(ShellTab.chat);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    final phone = MediaQuery.sizeOf(context).width < 840;
    final settings = ref.watch(settingsControllerProvider).value;
    final study = settings?.studyModeEnabled ?? true,
        creation = settings?.creationModeEnabled ?? true;
    final tabs = [
      const PrototypeTab(value: 'sets', label: '资料集'),
      const PrototypeTab(value: 'assets', label: '素材'),
      const PrototypeTab(value: 'gen', label: '生图记录'),
      if (study) const PrototypeTab(value: 'study', label: '学习'),
      if (creation) const PrototypeTab(value: 'story', label: '创作'),
    ];
    final selected = tabs.any((t) => t.value == _tab) ? _tab : 'sets';
    final library =
        ref.watch(studyControllerProvider).value ?? StudyLibrary.empty;
    Widget controls(List<Widget> children) =>
        Wrap(spacing: 6, runSpacing: 6, children: children);
    final body = switch (selected) {
      'assets' => LibraryBrowser(
        prototypeLibrary: true,
        repository: ref.watch(libraryRepositoryProvider),
        maxCount: 0,
        manageOnly: true,
      ),
      'gen' => const GenerationHistoryPage(embedded: true),
      'study' => ListView(
        padding: EdgeInsets.zero,
        children: [
          PrototypePanel(
            title: '学习空间',
            subtitle: '导师、课程、刷题、错题本、复习卡',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    for (final metric in [
                      '今日待复习 ${const SrsScheduler().dueQueue(library.cards).length}',
                      '进行中课程 ${library.courses.where((course) => course.status == 'active').length}',
                      '错题 ${library.wrongItems.where((wrong) => wrong.status == StudyWrongStatus.open).length}',
                    ])
                      Text(
                        metric,
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                controls([
                  PrototypeButton(
                    label: '开始今日复习',
                    small: true,
                    variant: PrototypeButtonVariant.primary,
                    onPressed: () => _open(const ReviewSessionPage()),
                  ),
                  PrototypeButton(
                    label: '找导师',
                    small: true,
                    onPressed: () => _open(const TutorSetupPage()),
                  ),
                  PrototypeButton(
                    label: '进入学习空间',
                    small: true,
                    onPressed: () => _open(const StudyHubPage()),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
      'story' => ListView(
        padding: EdgeInsets.zero,
        children: [
          PrototypePanel(
            title: '创作中心',
            subtitle: '导演故事、角色大乱斗、角色库、世界书',
            child: controls([
              PrototypeButton(
                label: '导演故事',
                small: true,
                variant: PrototypeButtonVariant.primary,
                onPressed: () => _open(const DirectorStorySetupPage()),
              ),
              PrototypeButton(
                label: '角色库',
                small: true,
                onPressed: () => _open(const CharacterLibraryPage()),
              ),
              PrototypeButton(
                label: '世界书',
                small: true,
                onPressed: () => _open(const WorldInfoPage()),
              ),
              PrototypeButton(
                label: '角色大乱斗',
                small: true,
                onPressed: () => _open(const EnsembleSetupPage()),
              ),
              PrototypeButton(
                label: '进入创作中心',
                small: true,
                onPressed: () => _open(const StudioPage()),
              ),
            ]),
          ),
        ],
      ),
      _ =>
        ref
            .watch(_resourceSetsProvider)
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Column(
                children: [
                  Text('资料集暂时无法读取：$error'),
                  PrototypeButton(
                    label: '重试',
                    small: true,
                    onPressed: () => ref.invalidate(_resourceSetsProvider),
                  ),
                ],
              ),
              data: (data) => ListView(
                padding: EdgeInsets.zero,
                children: [
                  Text(
                    '资料集是一组可供聊天引用的文档，和工作会话的执行位置分开管理。',
                    style: TextStyle(fontSize: 12, height: 1.6, color: c.muted),
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, size) {
                      final columns = ((size.maxWidth + 12) / 232)
                          .floor()
                          .clamp(1, 4);
                      final width =
                          (size.maxWidth - 12 * (columns - 1)) / columns;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final project in data.projects)
                            SizedBox(
                              key: ValueKey('resource-set-${project.id}'),
                              width: width,
                              child: PrototypePanel(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            project.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              color: c.ink,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '${data.counts[project.id] ?? 0} 份',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: c.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      project.instructions.isEmpty
                                          ? '—'
                                          : project.instructions,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: c.muted,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    controls([
                                      PrototypeButton(
                                        key: ValueKey(
                                          'resource-use-${project.id}',
                                        ),
                                        label: '在新聊天中引用',
                                        small: true,
                                        onPressed: () => _useSet(project.id),
                                      ),
                                      PrototypeButton(
                                        label: '管理',
                                        small: true,
                                        variant: PrototypeButtonVariant.ghost,
                                        onPressed: () =>
                                            _manage(id: project.id),
                                      ),
                                    ]),
                                  ],
                                ),
                              ),
                            ),
                          SizedBox(
                            width: width,
                            height: 112,
                            child: Material(
                              color: c.panel,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: c.accent.withValues(alpha: .5),
                                ),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _manage(create: true),
                                child: Center(
                                  child: Text(
                                    '＋ 新建资料集',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: c.accent,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: PrototypeButton(
                      label: '管理未引用资料集的会话',
                      small: true,
                      variant: PrototypeButtonVariant.ghost,
                      onPressed: () => _manage(id: ''),
                    ),
                  ),
                ],
              ),
            ),
    };
    return Scaffold(
      appBar: widget.shellHeader
          ? null
          : AppBar(
              toolbarHeight: 52,
              title: const Text(
                '资料库',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              automaticallyImplyLeading: false,
              leading: widget.onOpenNavigation == null
                  ? null
                  : PrototypeIconButton(
                      icon: Icons.menu,
                      onPressed: widget.onOpenNavigation,
                      tooltip: '打开侧边栏',
                    ),
            ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              phone ? 14 : 24,
              phone ? 14 : 20,
              phone ? 14 : 24,
              phone ? 24 : 32,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '资料库',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 16),
                PrototypeTabStrip(
                  tabs: tabs,
                  value: selected,
                  onChanged: (value) => setState(() => _tab = value),
                ),
                const SizedBox(height: 16),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('素材库')),
    body: LibraryBrowser(
      repository: ref.watch(libraryRepositoryProvider),
      maxCount: 0,
      manageOnly: true,
    ),
  );
}
