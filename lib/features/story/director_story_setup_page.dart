import 'dart:async';

import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/story_models.dart';
import '../../domain/story/director_prose_styles.dart';
import '../../domain/story/story_ai_assist.dart';
import '../../domain/story/story_length_budget.dart';
import '../../state/chat_controller.dart';
import '../../state/settings_controller.dart';
import '../shell/shell_tab.dart';
import 'ai_assist_widgets.dart';

/// Creates a story from a premise without requiring a pre-existing character.
///
/// The configured model acts as casting director and writer: it creates the
/// story-local cast and outline, then performs every role while the user
/// remains the director.
class DirectorStorySetupPage extends ConsumerStatefulWidget {
  const DirectorStorySetupPage({super.key});

  @override
  ConsumerState<DirectorStorySetupPage> createState() =>
      _DirectorStorySetupPageState();
}

class _DirectorStorySetupPageState
    extends ConsumerState<DirectorStorySetupPage> {
  static const _beatOptions = <int>[4, 6, 8, 10, 12, 16, 20];

  final _formKey = GlobalKey<FormState>();
  final _premise = TextEditingController();
  final _requirements = TextEditingController();
  final _title = TextEditingController();
  final _outline = TextEditingController();
  final _authorNote = TextEditingController(
    text: DirectorStoryDraft.defaultAuthorNote,
  );

  DirectorStoryDraft? _draft;
  CancelToken? _cancelToken;
  var _beatCount = 8;
  /// Novel target length in characters; 0 = unlimited.
  var _targetTotalChars = 80000;
  var _generating = false;
  var _starting = false;
  String? _error;
  String? _notice;

  /// Multi-select hard prose styles (日本轻小说 / 文言文 …).
  final Set<String> _styleIds = {};

  bool get _busy => _generating || _starting;

  String _mergedRequirements() => DirectorProseStyle.mergeRequirements(
    styleIds: _styleIds,
    freeform: _requirements.text,
  );

  void _toggleStyle(String id) {
    setState(() {
      final next = DirectorProseStyle.toggleSelection(_styleIds, id);
      _styleIds
        ..clear()
        ..addAll(next);
    });
  }

  @override
  void dispose() {
    _cancelToken?.cancel('页面已关闭');
    _premise.dispose();
    _requirements.dispose();
    _title.dispose();
    _outline.dispose();
    _authorNote.dispose();
    super.dispose();
  }

  DirectorStoryDraft? _editorSeed() {
    final current = _draft;
    if (current == null) return null;
    return DirectorStoryDraft(
      title: _title.text,
      outline: _outline.text,
      authorNote: _authorNote.text,
      characters: current.characters,
    );
  }

  void _applyDraft(DirectorStoryDraft draft) {
    _title.text = draft.title;
    _outline.text = draft.outline;
    _authorNote.text = draft.authorNote.trim().isEmpty
        ? DirectorStoryDraft.defaultAuthorNote
        : draft.authorNote;
    setState(() => _draft = draft);
  }

  Future<void> _generateDraft() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    final ready = await requireLlmReady(ref, context);
    if (ready == null || !mounted) {
      if (mounted) {
        setState(() => _error = '请先在设置中配置对话模型的 API，再生成故事方案。');
      }
      return;
    }

    final token = CancelToken();
    _cancelToken = token;
    setState(() {
      _generating = true;
      _error = null;
      _notice = null;
    });

    try {
      final requirements = _mergedRequirements();
      final lengthParts = <String>[
        '$_beatCount 个连续、具体且可以依次演绎的故事节拍',
        if (_targetTotalChars > 0)
          '全书目标约 ${StoryLengthBudget.formatChars(_targetTotalChars)}字'
          '（约每拍 ${StoryLengthBudget.formatChars((_targetTotalChars / _beatCount).round())}字，'
          'outline 密度须与总篇幅匹配，避免前松后紧）',
      ];
      final generated = await ready.assist.generateDirectorStory(
        config: ready.config,
        premise: _premise.text.trim(),
        // Hard creative constraints — styles + freeform, not mere flavor.
        requirements: requirements.isEmpty ? null : requirements,
        length: lengthParts.join('；'),
        seed: _editorSeed(),
        cancelToken: token,
      );
      if (!mounted) return;
      if (token.isCancelled) {
        setState(() => _notice = '已取消生成，现有内容不会丢失。');
        return;
      }
      _applyDraft(generated);
      setState(() => _notice = '故事方案已生成。你可以修改标题、大纲和导演指令后再开演。');
    } catch (e) {
      if (!mounted) return;
      if (e is DioException && CancelToken.isCancel(e)) {
        setState(() => _notice = '已取消生成，现有内容不会丢失。');
      } else {
        setState(() => _error = humanizeAiError(e));
      }
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
      if (mounted) setState(() => _generating = false);
    }
  }

  void _cancelGeneration() {
    final token = _cancelToken;
    if (token == null || token.isCancelled) return;
    token.cancel('用户取消');
    setState(() => _notice = '正在取消生成…');
  }

  Future<void> _startStory() async {
    if (_busy) return;
    final draft = _draft;
    if (draft == null) {
      setState(() => _error = '请先让 AI 生成角色和大纲。');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final outline = _outline.text.trim();
    if (parseOutlineBeats(outline).isEmpty) {
      setState(() => _error = '大纲至少需要一个可演绎的故事节拍。');
      return;
    }
    if (draft.characters.isEmpty) {
      setState(() => _error = '当前方案没有可用角色，请重新生成。');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _starting = true;
      _error = null;
      _notice = null;
    });

    final controller = ref.read(chatControllerProvider.notifier);
    // A stream still running in another conversation would turn the opening
    // advancePlot below into a silent no-op (global isStreaming guard). The
    // user explicitly chose to start the new story, so stop the old one.
    if (ref.read(chatControllerProvider).value?.isStreaming ?? false) {
      controller.stop();
    }
    try {
      await controller.newDirectorStoryConversation(
        title: _title.text.trim().isEmpty
            ? _premise.text.trim()
            : _title.text.trim(),
        premise: _premise.text.trim(),
        requirements: _mergedRequirements(),
        cast: [for (final character in draft.characters) character.toCard()],
        outline: outline,
        authorNote: _authorNote.text.trim().isEmpty
            ? DirectorStoryDraft.defaultAuthorNote
            : _authorNote.text.trim(),
        targetTotalChars: _targetTotalChars,
      );
      if (!mounted) return;

      // Return to the chat workspace first so the opening section streams
      // visibly instead of making the user wait on this setup form.
      openShellTab(ref, ShellTab.chat);
      Navigator.of(context).popUntil((route) => route.isFirst);
      unawaited(controller.advancePlot());
    } catch (e) {
      if (mounted) {
        setState(() => _error = humanizeAiError(e));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final modelConfigured = ref
        .watch(settingsControllerProvider)
        .value
        ?.config
        .isReady;

    return Scaffold(
      appBar: AppBar(
        title: const Text('导演故事'),
        actions: [
          if (_generating)
            TextButton(onPressed: _cancelGeneration, child: const Text('取消生成')),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 180),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                _IntroCard(scheme: scheme),
                if (modelConfigured == false) ...[
                  const SizedBox(height: 12),
                  const _ApiSetupWarning(),
                ],
                const SizedBox(height: 20),
                Text('故事种子', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  '只需要描述你想看到的情节。AI 会自动选角、写大纲，并在故事里扮演全部角色。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _premise,
                  enabled: !_starting,
                  minLines: 4,
                  maxLines: 9,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    labelText: '故事情节 *',
                    alignLabelWithHint: true,
                    hintText: '例如：一列永远到不了终点的夜车上，失忆的乘客逐渐发现，每个人都曾在同一天见过彼此。',
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请先输入故事情节' : null,
                ),
                const SizedBox(height: 16),
                Text('强制文风', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '可多选；作为硬性约束写入大纲生成与每一节演绎（可与下方自定义要求叠加）。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  key: const ValueKey('director-prose-style-chips'),
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final style in DirectorProseStyle.presets)
                      FilterChip(
                        key: ValueKey('director-style-${style.id}'),
                        selected: _styleIds.contains(style.id),
                        label: Text(style.label),
                        tooltip: style.constraint,
                        onSelected: _busy
                            ? null
                            : (_) => _toggleStyle(style.id),
                      ),
                  ],
                ),
                if (_styleIds.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '已选：${[
                      for (final p in DirectorProseStyle.presets)
                        if (_styleIds.contains(p.id)) p.label,
                    ].join('、')}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _requirements,
                  enabled: !_starting,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '其它创作要求 / 硬性约束（可选）',
                    alignLabelWithHint: true,
                    hintText: '例如：慢热；禁止提前揭晓真相；不要加入超自然元素',
                    helperText: '与上方文风一并写入导演说明，每一节演绎强制遵守',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _beatCount,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '大纲节拍数',
                    helperText: '节拍越多，故事的发展空间越长；生成后仍可直接修改大纲。',
                    helperMaxLines: 2,
                  ),
                  items: [
                    for (final count in _beatOptions)
                      DropdownMenuItem(value: count, child: Text('$count 个节拍')),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() => _beatCount = value);
                          }
                        },
                ),
                const SizedBox(height: 16),
                Text('小说总字数', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '写入会话后，每一节会按「剩余字数 ÷ 剩余节拍」约束本回合篇幅；可在情节面板随时改。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in StoryLengthBudget.presets)
                      ChoiceChip(
                        key: ValueKey('director-len-${preset.chars}'),
                        label: Text(preset.label),
                        selected: _targetTotalChars == preset.chars,
                        onSelected: _busy
                            ? null
                            : (_) => setState(
                                () => _targetTotalChars = preset.chars,
                              ),
                      ),
                  ],
                ),
                if (_targetTotalChars > 0) ...[
                  const SizedBox(height: 6),
                  Text(
                    '目标约 ${StoryLengthBudget.formatChars(_targetTotalChars)}字'
                    '（按 $_beatCount 拍均分，每拍约 '
                    '${StoryLengthBudget.formatChars((_targetTotalChars / _beatCount).round())}）',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (_generating) ...[
                  const SizedBox(height: 18),
                  const _GeneratingCard(),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  _InlineStatus(
                    icon: Icons.error_outline,
                    message: _error!,
                    color: scheme.error,
                    onDismiss: () => setState(() => _error = null),
                  ),
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 14),
                  _InlineStatus(
                    icon: Icons.info_outline,
                    message: _notice!,
                    color: scheme.primary,
                    onDismiss: () => setState(() => _notice = null),
                  ),
                ],
                if (_draft != null) ...[
                  const SizedBox(height: 28),
                  _buildDraftEditor(context, _draft!),
                ],
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomActions(context),
    );
  }

  Widget _buildDraftEditor(BuildContext context, DirectorStoryDraft draft) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.movie_creation_outlined, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '演绎方案',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Chip(
              avatar: const Icon(Icons.people_outline, size: 17),
              label: Text('${draft.characters.length} 位角色'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '这些角色仅服务于当前故事。AI 负责旁白和全部角色，你只需要下达导演指令。',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _title,
          enabled: !_starting,
          decoration: const InputDecoration(labelText: '故事标题'),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Text(
                '当前故事专属角色',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text(
              '不会加入角色库',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (var index = 0; index < draft.characters.length; index++) ...[
          _CastSummaryCard(character: draft.characters[index], index: index),
          if (index != draft.characters.length - 1) const SizedBox(height: 8),
        ],
        const SizedBox(height: 20),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _outline,
          builder: (context, value, _) {
            final actualBeats = parseOutlineBeats(value.text).length;
            return Row(
              children: [
                Expanded(
                  child: Text(
                    '故事大纲',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  '$actualBeats 个节拍',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _outline,
          enabled: !_starting,
          minLines: 8,
          maxLines: 18,
          decoration: const InputDecoration(
            alignLabelWithHint: true,
            hintText: '- 第一个情节节点\n- 第二个情节节点',
            helperText: '每个非空行视为一个节拍，演绎时会按顺序推进。',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 18),
        Text('导演总指令', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _authorNote,
          enabled: !_starting,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            alignLabelWithHint: true,
            hintText: '例如：AI 扮演全部角色；保持悬念；优先服从导演后续指令。',
            helperText: '该指令会持续参与后续演绎，你也可以在故事中随时追加导演指令。',
            helperMaxLines: 2,
          ),
        ),
      ],
    );
  }

  Widget _buildBottomActions(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasDraft = _draft != null;

    return Material(
      color: scheme.surface.withValues(alpha: 0.97),
      elevation: 3,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Align(
          alignment: Alignment.center,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final generateButton = hasDraft
                    ? OutlinedButton.icon(
                        onPressed: _busy ? null : _generateDraft,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新生成方案'),
                      )
                    : FilledButton.icon(
                        onPressed: _generating
                            ? _cancelGeneration
                            : (_starting ? null : _generateDraft),
                        icon: _generating
                            ? const Icon(Icons.stop_circle_outlined)
                            : const Icon(Icons.auto_awesome),
                        label: Text(_generating ? '取消生成' : 'AI 选角并生成大纲'),
                      );

                if (!hasDraft) {
                  return SizedBox(
                    width: double.infinity,
                    child: generateButton,
                  );
                }

                final startButton = FilledButton.icon(
                  onPressed: _busy ? null : _startStory,
                  icon: _starting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(_starting ? '正在创建…' : '开始演绎第一节'),
                );

                if (constraints.maxWidth < 520) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      startButton,
                      const SizedBox(height: 8),
                      generateButton,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: generateButton),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: startButton),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.42),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.theater_comedy_outlined,
                color: scheme.onPrimary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '你当导演，AI 扮演所有人',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '从一段情节出发，自动创建临时角色卡与故事大纲。确认方案后，AI 会直接写出第一节并按大纲继续。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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

class _ApiSetupWarning extends StatelessWidget {
  const _ApiSetupWarning();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.key_off_outlined, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '尚未配置对话模型 API。请先到“设置”填写 Base URL、模型和 API Key，再回来生成故事。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _GeneratingCard extends StatelessWidget {
  const _GeneratingCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI 正在选角和编排故事…',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '它会同时生成角色关系、动机、说话方式和可依次演绎的大纲。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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

class _InlineStatus extends StatelessWidget {
  const _InlineStatus({
    required this.icon,
    required this.message,
    required this.color,
    required this.onDismiss,
  });

  final IconData icon;
  final String message;
  final Color color;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
          IconButton(
            onPressed: onDismiss,
            tooltip: '关闭',
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

class _CastSummaryCard extends StatelessWidget {
  const _CastSummaryCard({required this.character, required this.index});

  final CharacterCardDraft character;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = character.name.trim().isEmpty
        ? '未命名角色 ${index + 1}'
        : character.name.trim();
    final initial = String.fromCharCode(name.runes.first);
    final description = character.description.trim();
    final personality = character.personality.trim();
    final summary = [
      if (description.isNotEmpty) description,
      if (personality.isNotEmpty) personality,
    ].join('\n');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
            child: Text(
              initial,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 3),
                Text(
                  summary.isEmpty ? 'AI 已为该角色生成完整角色卡。' : summary,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
