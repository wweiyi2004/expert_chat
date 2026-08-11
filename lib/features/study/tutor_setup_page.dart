import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mode_style.dart';
import '../../data/story_models.dart';
import '../../domain/study/tutor_style.dart';
import '../../state/chat_controller.dart';
import '../shell/shell_tab.dart';
import 'study_ui.dart';

class TutorSetupPage extends ConsumerStatefulWidget {
  const TutorSetupPage({
    super.key,
    this.initialTopic = '',
    this.courseId,
    this.nodeId,
  });

  final String initialTopic;
  final String? courseId;
  final String? nodeId;

  @override
  ConsumerState<TutorSetupPage> createState() => _TutorSetupPageState();
}

class _TutorSetupPageState extends ConsumerState<TutorSetupPage> {
  late final TextEditingController _topic;
  TutorStyle _style = TutorStyle.mixed;
  var _starting = false;

  @override
  void initState() {
    super.initState();
    _topic = TextEditingController(text: widget.initialTopic);
  }

  @override
  void dispose() {
    _topic.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final topic = _topic.text.trim();
    if (topic.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写学习主题')));
      return;
    }
    setState(() => _starting = true);
    try {
      await ref
          .read(chatControllerProvider.notifier)
          .newStudyConversation(
            topic: topic,
            tutorStyle: _style,
            path: StudyPath.tutor,
            courseId: widget.courseId,
            nodeId: widget.nodeId,
          );
      if (!mounted) return;
      openShellTab(ref, ShellTab.chat);
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法开始：$e')));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: const Text('导师'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: StudyContent(
        maxWidth: 780,
        children: [
          const StudyPageLead(
            icon: Icons.psychology_alt_outlined,
            title: '找一位适合你的导师',
            subtitle: '输入你正在学的内容，再选择一种交流方式。学习过程中可随时追问、自测或生成复习卡。',
          ),
          StudyPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const StudySectionTitle(
                  title: '你想学什么？',
                  subtitle: '越具体，导师越容易把握讲解的深度',
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _topic,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: '例如：我想理解线性代数中特征值的几何意义…',
                    filled: true,
                    fillColor: scheme.surface,
                    border: const OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!_starting) _start();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          StudyPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const StudySectionTitle(
                  title: '选择导师方式',
                  subtitle: '之后也可以直接告诉导师「给提示」或「完整讲解」',
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 620 ? 3 : 1;
                    return GridView.count(
                      crossAxisCount: columns,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: columns == 3 ? 1.45 : 2.7,
                      children: [
                        for (final style in TutorStyle.values)
                          _TutorStyleOption(
                            style: style,
                            selected: _style == style,
                            onTap: () => setState(() => _style = style),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _starting ? null : _start,
              icon: _starting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(ModeStyle.icon(ConversationMode.study)),
              label: Text(_starting ? '正在准备导师…' : '开始学习'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TutorStyleOption extends StatelessWidget {
  const _TutorStyleOption({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final TutorStyle style;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon => switch (style) {
    TutorStyle.socratic => Icons.question_answer_outlined,
    TutorStyle.feynman => Icons.lightbulb_outline_rounded,
    TutorStyle.mixed => Icons.auto_awesome_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? Color.alphaBlend(
              ModeStyle.study.withValues(alpha: 0.10),
              scheme.surface,
            )
          : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected
              ? ModeStyle.study.withValues(alpha: 0.50)
              : scheme.outlineVariant.withValues(alpha: 0.62),
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_icon, color: ModeStyle.study, size: 21),
                  const Spacer(),
                  if (selected)
                    const Icon(
                      Icons.check_circle_rounded,
                      color: ModeStyle.study,
                      size: 19,
                    ),
                ],
              ),
              const Spacer(),
              Text(
                style.label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                style.shortHint,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
