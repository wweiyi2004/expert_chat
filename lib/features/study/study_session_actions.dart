import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mode_style.dart';
import '../../data/models.dart';
import '../../data/study_models.dart';
import '../../domain/study/study_prompt_assembler.dart';
import '../../domain/study/tutor_style.dart';
import '../../state/study_controller.dart';
import 'quiz_setup_page.dart';
import 'study_generation_error.dart';

/// Action chips shown above the composer for study conversations.
class StudySessionActions extends ConsumerStatefulWidget {
  const StudySessionActions({super.key, required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<StudySessionActions> createState() =>
      _StudySessionActionsState();
}

class _StudySessionActionsState extends ConsumerState<StudySessionActions> {
  var _busy = false;

  StudySessionMeta? _sessionFrom(StudyLibrary? library) {
    if (library == null) return null;
    for (final session in library.sessions) {
      if (session.conversationId == widget.conversation.id) return session;
    }
    return null;
  }

  String get _topic {
    final session = _sessionFrom(ref.read(studyControllerProvider).value);
    final topic = session?.topic.trim();
    if (topic != null && topic.isNotEmpty) return topic;
    final legacy = StudyPromptAssembler.decodeSessionNote(
      widget.conversation.authorNote,
    );
    final legacyTopic = (legacy?['topic'] as String?)?.trim();
    if (legacyTopic != null && legacyTopic.isNotEmpty) return legacyTopic;
    return widget.conversation.title
        .replaceFirst(RegExp(r'^学习[：:]'), '')
        .trim();
  }

  String _transcript() {
    final buf = StringBuffer();
    for (final m in widget.conversation.activePath) {
      if (m.content.trim().isEmpty) continue;
      final role = switch (m.role) {
        MessageRole.user => '学生',
        MessageRole.assistant => '导师',
        _ => m.role.wire,
      };
      buf.writeln('$role：${m.content.trim()}');
    }
    return buf.toString();
  }

  Future<void> _summary() async {
    setState(() => _busy = true);
    try {
      final text = await ref
          .read(studyControllerProvider.notifier)
          .summarizeTranscript(_transcript());
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('本轮小结'),
          content: SingleChildScrollView(child: SelectableText(text)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('小结失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _makeCards() async {
    setState(() => _busy = true);
    try {
      final cards = await ref
          .read(studyControllerProvider.notifier)
          .generateCards(topic: _topic, context: _transcript(), count: 5);
      if (cards.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能解析卡片，请重试')));
        return;
      }
      await ref.read(studyControllerProvider.notifier).addCards(cards);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已加入 ${cards.length} 张复习卡')));
    } catch (e) {
      if (!mounted) return;
      await showStudyGenerationError(context, title: '生成卡片失败', error: e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _quiz() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QuizSetupPage(initialTopic: _topic, initialCount: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _sessionFrom(ref.watch(studyControllerProvider).value);
    final legacy = StudyPromptAssembler.decodeSessionNote(
      widget.conversation.authorNote,
    );
    final style =
        session?.tutorStyle ??
        TutorStyle.fromWire(legacy?['tutorStyle'] as String?);
    return Material(
      color: ModeStyle.study.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '学习 · ${style.label}${_topic.isEmpty ? '' : ' · $_topic'}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: ModeStyle.study,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ActionChip(
                    label: Text(_busy ? '…' : '本轮小结'),
                    onPressed: _busy ? null : _summary,
                    avatar: const Icon(Icons.summarize_outlined, size: 16),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('出 3 题'),
                    onPressed: _busy ? null : _quiz,
                    avatar: const Icon(Icons.quiz_outlined, size: 16),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('生成复习卡'),
                    onPressed: _busy ? null : _makeCards,
                    avatar: const Icon(Icons.style_outlined, size: 16),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
