import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/director_story_setup_draft.dart';
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

enum _SetupPhase { interview, editor }

class _DirectorStorySetupPageState
    extends ConsumerState<DirectorStorySetupPage> {
  static const _beatOptions = <int>[4, 6, 8, 10, 12, 16, 20];

  /// Genre chips may suggest a prose style, but an unspecified genre no longer
  /// silently forces the whole story into light-novel prose.
  static const _genreOptions = <({String id, String label, String? styleId})>[
    (id: 'school', label: '学园日常', styleId: 'jp_ln'),
    (id: 'isekai', label: '异世界', styleId: 'jp_ln'),
    (id: 'romcom', label: '恋爱喜剧', styleId: 'jp_ln'),
    (id: 'fantasy', label: '奇幻冒险', styleId: 'jp_ln'),
    (id: 'mystery', label: '悬疑推理', styleId: 'mystery_cool'),
    (id: 'action', label: '战斗热血', styleId: 'jp_ln'),
    (id: 'villainess', label: '转生/恶役', styleId: 'jp_ln'),
    (id: 'urban_ability', label: '都市异能', styleId: 'jp_ln'),
    (id: 'ensemble', label: '群像日常', styleId: 'jp_ln'),
    (id: 'other', label: '说不清 / 混合', styleId: null),
  ];

  /// Preset options plus any restored value that is no longer in the presets,
  /// so a non-preset [DropdownButton] value stays selectable instead of
  /// silently resetting to the default.
  List<int> get _effectiveBeatOptions {
    if (_beatOptions.contains(_beatCount)) return _beatOptions;
    return [..._beatOptions, _beatCount]..sort();
  }

  final _formKey = GlobalKey<FormState>();
  final _premise = TextEditingController();
  final _requirements = TextEditingController();
  final _title = TextEditingController();
  final _outline = TextEditingController();
  final _authorNote = TextEditingController(
    text: DirectorStoryDraft.defaultAuthorNote,
  );
  final _interviewHook = TextEditingController();
  final _interviewConstraint = TextEditingController();

  late final DirectorStorySetupDraftStore _localDraftStore;
  Timer? _draftSaveDebounce;
  DirectorStoryDraft? _draft;
  String? _draftInputFingerprint;
  CancelToken? _cancelToken;
  var _beatCount = 8;

  /// Novel target length in characters; 0 = unlimited.
  var _targetTotalChars = 80000;

  /// Default off: faster first draft; power users can enable in 更多设置.
  var _strictReview = false;

  /// Collapse styles / beats / length so the happy path is one premise field.
  var _showAdvanced = false;
  var _generating = false;
  var _starting = false;
  var _suppressDraftSave = false;
  var _discardDraftOnDispose = false;
  var _restoredDraftNotice = false;
  var _draftSaveErrorNotified = false;
  String? _error;
  String? _notice;

  /// Multi-select prose preferences. Empty means the model follows the premise.
  final Set<String> _styleIds = {};

  /// Opening interview before the freeform editor.
  var _phase = _SetupPhase.interview;
  var _interviewStep = 0; // 0 genre, 1 hook, 2 constraints, 3 confirm
  final Set<String> _interviewGenres = {};

  bool get _busy => _generating || _starting;

  @override
  void initState() {
    super.initState();
    _localDraftStore = DirectorStorySetupDraftStore(
      ref.read(sharedPrefsProvider),
    );
    _restoreLocalDraft();
    for (final controller in [
      _premise,
      _requirements,
      _title,
      _outline,
      _authorNote,
    ]) {
      controller.addListener(_scheduleDraftSave);
    }
  }

  void _skipInterview() {
    setState(() {
      _phase = _SetupPhase.editor;
      _interviewStep = 0;
    });
  }

  void _restartInterview() {
    setState(() {
      _phase = _SetupPhase.interview;
      _interviewStep = 0;
      _interviewGenres.clear();
      _interviewHook.clear();
      _interviewConstraint.clear();
    });
  }

  void _toggleInterviewGenre(String id) {
    setState(() {
      if (_interviewGenres.contains(id)) {
        _interviewGenres.remove(id);
      } else {
        _interviewGenres.add(id);
      }
    });
  }

  String _composePremiseFromInterview() {
    final genres = [
      for (final g in _genreOptions)
        if (_interviewGenres.contains(g.id)) g.label,
    ];
    final hook = _interviewHook.text.trim();
    final buf = StringBuffer();
    if (genres.isNotEmpty) {
      buf.writeln('【想要的类型】${genres.join('、')}');
    }
    if (hook.isNotEmpty) {
      buf.writeln('【主线剧情】$hook');
    }
    return buf.toString().trim();
  }

  void _applyInterviewToEditor({required bool thenQuickStart}) {
    final composed = _composePremiseFromInterview();
    if (composed.isEmpty && _interviewHook.text.trim().isEmpty) {
      setState(() => _error = '请先说说你想写的主线剧情。');
      return;
    }
    final hook = _interviewHook.text.trim();
    final premise = composed.isEmpty ? hook : composed;
    final constraint = _interviewConstraint.text.trim();

    // Map only explicit genre choices to prose styles. The premise and the
    // constraint field stay separate so the same rule is not stored twice.
    var nextStyles = <String>{};
    for (final g in _genreOptions) {
      if (_interviewGenres.contains(g.id) && g.styleId != null) {
        nextStyles = DirectorProseStyle.toggleSelection(nextStyles, g.styleId!);
      }
    }
    _styleIds
      ..clear()
      ..addAll(nextStyles);

    _suppressDraftSave = true;
    _premise.text = premise;
    if (constraint.isNotEmpty && !_requirements.text.contains(constraint)) {
      final prev = _requirements.text.trim();
      _requirements.text = prev.isEmpty ? constraint : '$prev\n$constraint';
    }
    _suppressDraftSave = false;
    _scheduleDraftSave();

    setState(() {
      _phase = _SetupPhase.editor;
      _error = null;
      _notice = thenQuickStart ? null : '已根据访谈填入故事种子，可改后再开书。';
    });

    if (thenQuickStart) {
      unawaited(_quickStart());
    }
  }

  bool get _interviewCanNext {
    return switch (_interviewStep) {
      0 => true, // genre optional
      1 => _interviewHook.text.trim().isNotEmpty,
      2 => true,
      3 =>
        _interviewHook.text.trim().isNotEmpty ||
            _composePremiseFromInterview().isNotEmpty,
      _ => false,
    };
  }

  Iterable<String> get _orderedStyleIds sync* {
    for (final style in DirectorProseStyle.presets) {
      if (_styleIds.contains(style.id)) yield style.id;
    }
  }

  String _mergedRequirements() => DirectorProseStyle.mergeRequirements(
    styleIds: _orderedStyleIds,
    freeform: _requirements.text,
  );

  String _generationFingerprint({
    String? premise,
    String? requirements,
    int? beatCount,
    int? targetTotalChars,
    bool? strictReview,
  }) {
    return jsonEncode({
      'premise': premise ?? _premise.text.trim(),
      'requirements': requirements ?? _mergedRequirements(),
      'beatCount': beatCount ?? _beatCount,
      'targetTotalChars': targetTotalChars ?? _targetTotalChars,
      'strictReview': strictReview ?? _strictReview,
    });
  }

  void _toggleStyle(String id) {
    setState(() {
      final next = DirectorProseStyle.toggleSelection(_styleIds, id);
      _styleIds
        ..clear()
        ..addAll(next);
    });
    _scheduleDraftSave();
  }

  void _restoreLocalDraft() {
    final saved = _localDraftStore.read();
    if (saved == null || !saved.hasMeaningfulContent) return;

    _suppressDraftSave = true;
    _premise.text = saved.premise;
    _requirements.text = saved.requirements;
    _styleIds
      ..clear()
      ..addAll(
        saved.styleIds.where((id) => DirectorProseStyle.byId(id) != null),
      );
    // Restore the saved values even when they are not in the current preset
    // options; otherwise the draft silently falls back to 8 / 80000 and the
    // generation fingerprint no longer matches the restored input.
    if (saved.beatCount >= 1) {
      _beatCount = saved.beatCount;
    }
    _targetTotalChars = saved.targetTotalChars;
    _strictReview = saved.strictReview;

    final generated = saved.generatedDraft;
    if (generated != null && !generated.isEmpty) {
      _draft = generated;
      var fingerprint = saved.generationFingerprint.trim().isEmpty
          ? _generationFingerprint()
          : saved.generationFingerprint;
      _draftInputFingerprint = fingerprint;
      _title.text = generated.title;
      _outline.text = generated.outline;
      _authorNote.text = generated.authorNote.trim().isEmpty
          ? DirectorStoryDraft.defaultAuthorNote
          : generated.authorNote;
    }
    // Resume in editor when we already have a seed or plan.
    _phase = _SetupPhase.editor;
    _restoredDraftNotice = true;
    _suppressDraftSave = false;
  }

  DirectorStorySetupDraft _snapshotLocalDraft() {
    final currentDraft = _draft;
    return DirectorStorySetupDraft(
      premise: _premise.text,
      requirements: _requirements.text,
      styleIds: [
        for (final style in DirectorProseStyle.presets)
          if (_styleIds.contains(style.id)) style.id,
      ],
      beatCount: _beatCount,
      targetTotalChars: _targetTotalChars,
      strictReview: _strictReview,
      generationFingerprint: _draftInputFingerprint ?? '',
      generatedDraft: currentDraft == null
          ? null
          : DirectorStoryDraft(
              title: _title.text,
              outline: _outline.text,
              authorNote: _authorNote.text,
              characters: currentDraft.characters,
            ),
      savedAt: DateTime.now(),
    );
  }

  void _scheduleDraftSave() {
    if (_suppressDraftSave || _discardDraftOnDispose) return;
    _draftSaveDebounce?.cancel();
    _draftSaveDebounce = Timer(
      const Duration(milliseconds: 550),
      () => unawaited(_saveDraftNow()),
    );
  }

  Future<void> _saveDraftNow() async {
    if (_suppressDraftSave || _discardDraftOnDispose) return;
    try {
      await _localDraftStore.save(_snapshotLocalDraft());
      _draftSaveErrorNotified = false;
    } catch (error) {
      debugPrint('Director story draft save failed: $error');
      // Surface persistence failures once per failure streak instead of
      // re-toasting on every debounce tick.
      if (!_draftSaveErrorNotified && mounted) {
        _draftSaveErrorNotified = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('草稿保存失败，请检查存储空间。'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _confirmClearDraft() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空当前草稿？'),
        content: const Text('故事种子、文风、字数设置和已生成的角色大纲都会被清空。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _draftSaveDebounce?.cancel();
    _suppressDraftSave = true;
    _premise.clear();
    _requirements.clear();
    _title.clear();
    _outline.clear();
    _authorNote.text = DirectorStoryDraft.defaultAuthorNote;
    _interviewHook.clear();
    _interviewConstraint.clear();
    setState(() {
      _styleIds.clear();
      _interviewGenres.clear();
      _interviewStep = 0;
      _phase = _SetupPhase.interview;
      _beatCount = 8;
      _targetTotalChars = 80000;
      _strictReview = false;
      _showAdvanced = false;
      _draft = null;
      _draftInputFingerprint = null;
      _error = null;
      _notice = null;
      _restoredDraftNotice = false;
    });
    await _localDraftStore.clear();
    _suppressDraftSave = false;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('草稿已清空，可以重新开始。'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel('页面已关闭');
    _draftSaveDebounce?.cancel();
    for (final controller in [
      _premise,
      _requirements,
      _title,
      _outline,
      _authorNote,
    ]) {
      controller.removeListener(_scheduleDraftSave);
    }
    if (!_discardDraftOnDispose) {
      unawaited(_saveDraftNow());
    }
    _premise.dispose();
    _requirements.dispose();
    _title.dispose();
    _outline.dispose();
    _authorNote.dispose();
    _interviewHook.dispose();
    _interviewConstraint.dispose();
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

  void _applyDraft(DirectorStoryDraft draft, {required String generatedFrom}) {
    _title.text = draft.title;
    _outline.text = draft.outline;
    _authorNote.text = draft.authorNote.trim().isEmpty
        ? DirectorStoryDraft.defaultAuthorNote
        : draft.authorNote;
    setState(() {
      _draft = draft;
      _draftInputFingerprint = generatedFrom;
    });
    _scheduleDraftSave();
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
      final premise = _premise.text.trim();
      final requirements = _mergedRequirements();
      final beatCount = _beatCount;
      final targetTotalChars = _targetTotalChars;
      final strictReview = _strictReview;
      final generatedFrom = _generationFingerprint(
        premise: premise,
        requirements: requirements,
        beatCount: beatCount,
        targetTotalChars: targetTotalChars,
        strictReview: strictReview,
      );
      final seed = _editorSeed();
      final lengthParts = <String>[
        '$beatCount 个连续、具体且可以依次演绎的故事节拍',
        if (targetTotalChars > 0)
          '全书目标约 ${StoryLengthBudget.formatChars(targetTotalChars)}字'
              '（约每拍 ${StoryLengthBudget.formatChars((targetTotalChars / beatCount).round())}字，'
              'outline 密度须与总篇幅匹配，避免前松后紧）',
      ];
      final generated = await ready.assist.generateDirectorStory(
        config: ready.config,
        premise: premise,
        // Typed prose preferences plus the separate full-book constraints.
        requirements: requirements.isEmpty ? null : requirements,
        length: lengthParts.join('；'),
        expectedBeatCount: beatCount,
        strictReview: strictReview,
        seed: seed,
        cancelToken: token,
      );
      if (!mounted) return;
      if (token.isCancelled) {
        setState(() => _notice = '已取消生成，现有内容不会丢失。');
        return;
      }
      _applyDraft(generated, generatedFrom: generatedFrom);
      setState(
        () => _notice = strictReview
            ? '故事方案已生成，并完成严格审稿。你可以修改后再开演。'
            : '故事方案已生成。你可以修改标题、大纲和导演指令后再开演。',
      );
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

  /// One-tap path: generate cast+outline, respecting the current review option,
  /// then open chat.
  Future<void> _quickStart() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await _generateDraft();
    if (!mounted) return;
    if (_draft == null || _error != null) return;
    await _startStory();
  }

  Future<void> _startStory() async {
    if (_busy) return;
    final draft = _draft;
    if (draft == null) {
      setState(() => _error = '请先输入情节并点「一句话开书」，或先生成方案。');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_draftInputFingerprint != _generationFingerprint()) {
      setState(
        () => _error =
            '故事情节、文风、创作要求、节拍、篇幅或审稿设置已变化，请先重新生成方案。'
            '标题、大纲和导演指令仍可直接修改。',
      );
      return;
    }

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
    try {
      // AsyncNotifier methods can be invoked while build() is still loading;
      // wait for the repository snapshot so it cannot overwrite the new story.
      await ref.read(chatControllerProvider.future);
      // Includes the pre-stream settings/prompt window, where isStreaming is
      // still false but a replacement advancePlot would otherwise be dropped.
      await controller.stopAndWait();
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

      _draftSaveDebounce?.cancel();
      _discardDraftOnDispose = true;
      await _localDraftStore.clear();
      if (!mounted) return;

      // Jump to chat so writing feels continuous with normal conversation.
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
          IconButton(
            tooltip: '清空草稿',
            onPressed: _busy ? null : _confirmClearDraft,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                _phase == _SetupPhase.interview ? 120 : 180,
              ),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                if (_phase == _SetupPhase.interview)
                  _buildInterview(context, scheme)
                else ...[
                  _IntroCard(scheme: scheme),
                  if (_restoredDraftNotice) ...[
                    const SizedBox(height: 12),
                    _InlineStatus(
                      icon: Icons.restore_rounded,
                      message: '已恢复上次未完成的故事草稿。',
                      color: scheme.primary,
                      onDismiss: () =>
                          setState(() => _restoredDraftNotice = false),
                    ),
                  ],
                  if (modelConfigured == false) ...[
                    const SizedBox(height: 12),
                    const _ApiSetupWarning(),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('director-restart-interview'),
                      onPressed: _busy ? null : _restartInterview,
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('重新问我想写什么'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('故事种子', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    '由访谈生成，可直接改。点下方开书即可进聊天。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _premise,
                    enabled: !_busy,
                    minLines: 4,
                    maxLines: 9,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      labelText: '故事情节 *',
                      alignLabelWithHint: true,
                      hintText: '例如：一列永远到不了终点的夜车上，失忆的乘客逐渐发现，每个人都曾在同一天见过彼此。',
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请先输入故事情节'
                        : null,
                  ),
                  const SizedBox(height: 8),
                  ExpansionTile(
                    key: const ValueKey('director-advanced-settings'),
                    initiallyExpanded: _showAdvanced,
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: Text(
                      '更多设置（文风 / 节拍 / 字数 / 审稿）',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      _showAdvanced ? '收起后仍会记住你的选择' : '可选 · 不展开也能直接开书',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    onExpansionChanged: (open) =>
                        setState(() => _showAdvanced = open),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '文风偏好',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(height: 8),
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
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _requirements,
                        enabled: !_busy,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: '其它创作要求 / 硬性约束（可选）',
                          alignLabelWithHint: true,
                          hintText: '例如：慢热；禁止提前揭晓真相；不要加入超自然元素',
                          helperText: '作为全书硬约束单独保存；不会重复写入故事情节。',
                          helperMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: _beatCount,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '大纲节拍数',
                          helperText: '节拍越多故事越长；生成后仍可改大纲。',
                          helperMaxLines: 2,
                        ),
                        items: [
                          for (final count in _effectiveBeatOptions)
                            DropdownMenuItem(
                              value: count,
                              child: Text('$count 个节拍'),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => _beatCount = value);
                                  _scheduleDraftSave();
                                }
                              },
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '小说总字数',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(height: 8),
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
                                  : (_) {
                                      setState(
                                        () => _targetTotalChars = preset.chars,
                                      );
                                      _scheduleDraftSave();
                                    },
                            ),
                        ],
                      ),
                      if (_targetTotalChars > 0) ...[
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '目标约 ${StoryLengthBudget.formatChars(_targetTotalChars)}字'
                            '（按 $_beatCount 拍均分）',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
                      SwitchListTile(
                        key: const ValueKey('director-strict-review'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('严格审稿'),
                        subtitle: const Text('生成后再检查情节与禁忌；会多一次模型调用，更慢。'),
                        value: _strictReview,
                        onChanged: _busy
                            ? null
                            : (value) {
                                setState(() => _strictReview = value);
                                _scheduleDraftSave();
                              },
                      ),
                    ],
                  ),
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
                ], // end editor phase
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomActions(context),
    );
  }

  Widget _buildInterview(BuildContext context, ColorScheme scheme) {
    const totalSteps = 4;
    final step = _interviewStep.clamp(0, totalSteps - 1);
    final titles = ['你想写什么类型的故事？', '主线剧情是什么？', '有没有必须遵守的点？', '确认一下，是这个意思吗？'];
    final subtitles = [
      '可多选。类型只提供适合的文风建议；没有想法也可以跳过。',
      '谁、在哪、发生了什么；可顺带写主角与 1～2 个关键配角的关系。',
      '可选。例如：HE、慢热、禁止后宫、不要系统面板、第一人称…',
      '确认后可直接开书；每次围绕一个明确场景目标写作。',
    ];

    return Column(
      key: const ValueKey('director-plot-interview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _IntroCard(scheme: scheme, compact: true),
        const SizedBox(height: 12),
        Row(
          children: [
            for (var i = 0; i < totalSteps; i++) ...[
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= step
                        ? scheme.primary
                        : scheme.outlineVariant.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              if (i < totalSteps - 1) const SizedBox(width: 6),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '第 ${step + 1} / $totalSteps 步',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(titles[step], style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          subtitles[step],
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (step == 0)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final g in _genreOptions)
                FilterChip(
                  key: ValueKey('interview-genre-${g.id}'),
                  selected: _interviewGenres.contains(g.id),
                  label: Text(g.label),
                  onSelected: (_) => _toggleInterviewGenre(g.id),
                ),
            ],
          ),
        if (step == 1)
          TextField(
            key: const ValueKey('interview-hook-field'),
            controller: _interviewHook,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '主线剧情 *',
              alignLabelWithHint: true,
              hintText: '例如：失忆少女在永远到不了站的夜车上醒来，发现每位乘客的车票日期都是自己的忌日…',
            ),
            onChanged: (_) => setState(() {}),
          ),
        if (step == 2)
          TextField(
            key: const ValueKey('interview-constraint-field'),
            controller: _interviewConstraint,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '必须做到 / 不要出现（可选）',
              alignLabelWithHint: true,
              hintText: '例如：HE；慢热；禁止开后宫；不要系统流',
            ),
          ),
        if (step == 3) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              _composePremiseFromInterview().isEmpty
                  ? '（还没有主线，请返回上一步填写）'
                  : _composePremiseFromInterview(),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '确认无误可直接「按此开书」；若想再改字句，选「填入后自己改」。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
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
      ],
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
          enabled: !_busy,
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
          enabled: !_busy,
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
          enabled: !_busy,
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
            child: _phase == _SetupPhase.interview
                ? _buildInterviewActions(context)
                : LayoutBuilder(
                    builder: (context, constraints) {
                      if (!hasDraft) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FilledButton.icon(
                              key: const ValueKey('director-quick-start'),
                              onPressed: _generating
                                  ? _cancelGeneration
                                  : (_starting ? null : _quickStart),
                              icon: _generating
                                  ? const Icon(Icons.stop_circle_outlined)
                                  : _starting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.auto_awesome),
                              label: Text(
                                _generating
                                    ? '取消生成'
                                    : _starting
                                    ? '正在进入聊天…'
                                    : '一句话开书',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: _busy ? null : _generateDraft,
                              child: const Text('仅生成方案（先预览再开写）'),
                            ),
                          ],
                        );
                      }

                      final generateButton = OutlinedButton.icon(
                        onPressed: _busy ? null : _generateDraft,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新生成'),
                      );
                      final startButton = FilledButton.icon(
                        onPressed: _busy ? null : () => _startStory(),
                        icon: _starting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.chat_rounded),
                        label: Text(_starting ? '正在进入聊天…' : '进入聊天 · 写第一场'),
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

  Widget _buildInterviewActions(BuildContext context) {
    final isFirst = _interviewStep <= 0;
    final isLast = _interviewStep >= 3;

    final skipButton = TextButton(
      key: const ValueKey('director-skip-interview'),
      onPressed: _busy ? null : _skipInterview,
      child: const Text('跳过引导，直接写情节'),
    );

    if (isLast) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            key: const ValueKey('interview-confirm-start'),
            onPressed: _busy
                ? null
                : () => _applyInterviewToEditor(thenQuickStart: true),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('按此开书'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey('interview-confirm-edit'),
            onPressed: _busy
                ? null
                : () => _applyInterviewToEditor(thenQuickStart: false),
            child: const Text('填入后自己改'),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _interviewStep = 1;
                    _error = null;
                  }),
            child: const Text('返回改主线'),
          ),
          skipButton,
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (!isFirst)
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _interviewStep -= 1;
                          _error = null;
                        }),
                  child: const Text('上一步'),
                ),
              ),
            if (!isFirst) const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                key: const ValueKey('interview-next'),
                onPressed: !_interviewCanNext || _busy
                    ? null
                    : () {
                        if (_interviewStep == 1 &&
                            _interviewHook.text.trim().isEmpty) {
                          setState(() => _error = '请先写一句主线剧情。');
                          return;
                        }
                        setState(() {
                          _interviewStep += 1;
                          _error = null;
                        });
                      },
                child: const Text('下一步'),
              ),
            ),
          ],
        ),
        skipButton,
      ],
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.scheme, this.compact = false});

  final ColorScheme scheme;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.42),
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: compact ? 36 : 42,
              height: compact ? 36 : 42,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.theater_comedy_outlined,
                color: scheme.onPrimary,
                size: compact ? 20 : 24,
              ),
            ),
            SizedBox(width: compact ? 10 : 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    compact ? '先聊聊你想写什么故事' : '像聊天一样写故事',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    compact
                        ? '类型 → 主线 → 约束 → 开书。文风只在你选择后生效。'
                        : '写清情节 → 点「一句话开书」→ 进聊天写第一场。'
                              '之后可发导演指令、写下一场或续写当前场。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(height: 6),
                    Text(
                      '没有默认强制文风；可在「更多设置」中组合文体、类型语气与叙事视角。草稿会自动保存在本机。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
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
