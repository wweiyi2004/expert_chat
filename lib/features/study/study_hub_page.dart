import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mode_style.dart';
import '../../data/models.dart';
import '../../data/study_models.dart';
import '../../domain/study/srs_scheduler.dart';
import '../../state/chat_controller.dart';
import '../../state/study_controller.dart';
import '../shell/shell_tab.dart';
import 'card_library_page.dart';
import 'course_detail_page.dart';
import 'course_list_page.dart';
import 'quiz_setup_page.dart';
import 'review_session_page.dart';
import 'study_ui.dart';
import 'tutor_setup_page.dart';
import 'wrong_book_page.dart';

/// A calm learning workspace: one visual language, clear next action, and the
/// library kept secondary to active learning.
class StudyHubPage extends ConsumerWidget {
  const StudyHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library =
        ref.watch(studyControllerProvider).value ?? StudyLibrary.empty;
    final due = const SrsScheduler().dueQueue(library.cards).length;
    final openWrong = library.wrongItems
        .where((item) => item.status == StudyWrongStatus.open)
        .length;
    final activeCourses = library.courses
        .where((course) => course.status == 'active')
        .length;
    final conversations = ref
        .watch(chatControllerProvider)
        .value
        ?.conversations
        .where((conversation) => conversation.isStudy)
        .take(2)
        .toList();
    final studyConversations = conversations ?? const [];
    final continueCourses = library.courses
        .where((course) {
          final leaves = library.nodes.where(
            (node) =>
                node.courseId == course.id && node.kind == StudyNodeKind.leaf,
          );
          return leaves.any((node) => node.progress != StudyNodeProgress.done);
        })
        .take(3)
        .toList();
    final hasContinue =
        due > 0 || continueCourses.isNotEmpty || studyConversations.isNotEmpty;

    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: const Text('学习空间'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 36),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _LearningHero(
                    due: due,
                    activeCourses: activeCourses,
                    openWrong: openWrong,
                  ),
                  const SizedBox(height: 28),
                  const _SectionHeading(
                    title: '开始学习',
                    subtitle: '按你此刻的目标，选择最合适的方式',
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 820
                          ? 4
                          : constraints.maxWidth >= 390
                          ? 2
                          : 1;
                      final ratio = switch (columns) {
                        4 => 1.08,
                        2 => 1.34,
                        _ => 2.65,
                      };
                      return GridView.count(
                        crossAxisCount: columns,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: ratio,
                        children: [
                          _LearningPathCard(
                            icon: Icons.psychology_alt_outlined,
                            title: '导师',
                            subtitle: '讲清概念，随时追问',
                            emphasized: true,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const TutorSetupPage(),
                              ),
                            ),
                          ),
                          _LearningPathCard(
                            icon: Icons.route_outlined,
                            title: '课程',
                            subtitle: '沿知识路径逐关推进',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const CourseListPage(),
                              ),
                            ),
                          ),
                          _LearningPathCard(
                            icon: Icons.task_alt_outlined,
                            title: '刷题',
                            subtitle: '用练习检查真实掌握',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const QuizSetupPage(),
                              ),
                            ),
                          ),
                          _LearningPathCard(
                            icon: Icons.layers_outlined,
                            title: '复习',
                            subtitle: due > 0 ? '$due 张卡片等待复习' : '巩固已经学过的内容',
                            badge: due > 0 ? '$due' : null,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const ReviewSessionPage(),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (hasContinue) ...[
                    const SizedBox(height: 30),
                    const _SectionHeading(
                      title: '继续学习',
                      subtitle: '从上次停下的地方接着来',
                    ),
                    const SizedBox(height: 12),
                    _ContinuePanel(
                      due: due,
                      courses: continueCourses,
                      conversations: studyConversations,
                      onReview: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ReviewSessionPage(),
                        ),
                      ),
                      onCourse: (course) => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CourseDetailPage(courseId: course.id),
                        ),
                      ),
                      onConversation: (conversation) {
                        ref
                            .read(chatControllerProvider.notifier)
                            .selectConversation(conversation.id);
                        openShellTab(ref, ShellTab.chat);
                      },
                    ),
                  ],
                  const SizedBox(height: 30),
                  const _SectionHeading(
                    title: '学习资料库',
                    subtitle: '管理长期积累的课程、卡片和错题',
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 620 ? 3 : 1;
                      return GridView.count(
                        crossAxisCount: columns,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: columns == 3 ? 2.55 : 4.5,
                        children: [
                          _LibraryLink(
                            icon: Icons.account_tree_outlined,
                            label: '我的课程',
                            value: '$activeCourses',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const CourseListPage(),
                              ),
                            ),
                          ),
                          _LibraryLink(
                            icon: Icons.style_outlined,
                            label: '复习卡片',
                            value: '${library.cards.length}',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const CardLibraryPage(),
                              ),
                            ),
                          ),
                          _LibraryLink(
                            icon: Icons.error_outline_rounded,
                            label: '错题本',
                            value: '$openWrong',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const WrongBookPage(),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LearningHero extends StatelessWidget {
  const _LearningHero({
    required this.due,
    required this.activeCourses,
    required this.openWrong,
  });

  final int due;
  final int activeCourses;
  final int openWrong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final headline = due > 0 ? '今天，先完成一次复习' : '今天，学懂一件事';
    final subtitle = due > 0
        ? '有 $due 张卡片已到复习时间，几分钟就能完成。'
        : '从一个问题开始，让讲解、练习和复习连成一条路。';
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              ModeStyle.study.withValues(alpha: 0.14),
              scheme.surfaceContainerLow,
            ),
            Color.alphaBlend(
              ModeStyle.study.withValues(alpha: 0.035),
              scheme.surfaceContainerLow,
            ),
          ],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: ModeStyle.study.withValues(alpha: 0.16)),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -40,
            top: -52,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ModeStyle.study.withValues(alpha: 0.055),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: ModeStyle.study,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: const Icon(
                    Icons.school_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  headline,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 7),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 610),
                  child: Text(
                    subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 20,
                  runSpacing: 10,
                  children: [
                    _HeroMetric(value: '$due', label: '待复习'),
                    _HeroMetric(value: '$activeCourses', label: '进行中课程'),
                    _HeroMetric(value: '$openWrong', label: '待消化错题'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  const _HeroMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            color: ModeStyle.study,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _LearningPathCard extends StatelessWidget {
  const _LearningPathCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.emphasized = false,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool emphasized;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = emphasized
        ? Color.alphaBlend(
            ModeStyle.study.withValues(alpha: 0.095),
            scheme.surfaceContainerLow,
          )
        : scheme.surfaceContainerLow;
    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: emphasized
              ? ModeStyle.study.withValues(alpha: 0.24)
              : scheme.outlineVariant.withValues(alpha: 0.58),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: ModeStyle.study.withValues(
                        alpha: emphasized ? 0.16 : 0.09,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: ModeStyle.study, size: 23),
                  ),
                  const Spacer(),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: ModeStyle.study,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        badge!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContinuePanel extends StatelessWidget {
  const _ContinuePanel({
    required this.due,
    required this.courses,
    required this.conversations,
    required this.onReview,
    required this.onCourse,
    required this.onConversation,
  });

  final int due;
  final List<StudyCourse> courses;
  final List<Conversation> conversations;
  final VoidCallback onReview;
  final ValueChanged<StudyCourse> onCourse;
  final ValueChanged<Conversation> onConversation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final itemCount = (due > 0 ? 1 : 0) + courses.length + conversations.length;
    var index = 0;
    Widget item(Widget child) {
      final current = index++;
      return Column(
        children: [
          child,
          if (current < itemCount - 1)
            Divider(
              height: 1,
              indent: 64,
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
        ],
      );
    }

    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.58)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (due > 0)
            item(
              _ContinueTile(
                icon: Icons.replay_rounded,
                title: '今日复习',
                subtitle: '$due 张卡片已到复习时间',
                onTap: onReview,
              ),
            ),
          for (final course in courses)
            item(
              _ContinueTile(
                icon: Icons.route_outlined,
                title: course.title,
                subtitle: '继续课程进度',
                onTap: () => onCourse(course),
              ),
            ),
          for (final conversation in conversations)
            item(
              _ContinueTile(
                icon: Icons.forum_outlined,
                title: conversation.title,
                subtitle: '继续上次的导师对话',
                onTap: () => onConversation(conversation),
              ),
            ),
        ],
      ),
    );
  }
}

class _ContinueTile extends StatelessWidget {
  const _ContinueTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: ModeStyle.study.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 20, color: ModeStyle.study),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      ),
      trailing: Icon(
        Icons.arrow_forward_rounded,
        size: 18,
        color: scheme.outline,
      ),
      onTap: onTap,
    );
  }
}

class _LibraryLink extends StatelessWidget {
  const _LibraryLink({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(17),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.58)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Icon(icon, color: ModeStyle.study, size: 22),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
