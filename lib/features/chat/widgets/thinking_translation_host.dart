import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/model_service_routing.dart';
import '../../../state/reasoning_translation.dart';
import '../../../state/settings_controller.dart';
import 'composer_popover.dart';

enum ReasoningTranslationView { original, chinese, comparison }

class _TranslationPreferences {
  const _TranslationPreferences({
    this.model = '',
    this.view = ReasoningTranslationView.original,
  });
  final String model;
  final ReasoningTranslationView view;
}

final _translationPreferencesProvider =
    NotifierProvider<
      _TranslationPreferencesStore,
      Map<String, _TranslationPreferences>
    >(_TranslationPreferencesStore.new);

class _TranslationPreferencesStore
    extends Notifier<Map<String, _TranslationPreferences>> {
  @override
  Map<String, _TranslationPreferences> build() => {};
  void save(String key, _TranslationPreferences value) =>
      state = {...state, key: value};
}

typedef ReasoningSegmentRenderer =
    Widget Function(int index, String source, Widget original);
typedef ReasoningTranslationBuilder =
    Widget Function(Widget controls, ReasoningSegmentRenderer render);

/// Optional adapter: standalone message widgets need neither provider scope nor
/// session IDs. Timeline segmentation is always performed on the original text.
class ThinkingTranslationHost extends StatelessWidget {
  const ThinkingTranslationHost({
    super.key,
    required this.conversationId,
    required this.messageId,
    required this.segments,
    required this.isStreaming,
    required this.expanded,
    required this.builder,
  });
  final String? conversationId, messageId;
  final List<String> segments;
  final bool isStreaming, expanded;
  final ReasoningTranslationBuilder builder;
  @override
  Widget build(BuildContext context) {
    if (conversationId == null || messageId == null || segments.isEmpty) {
      return builder(const SizedBox.shrink(), (_, _, original) => original);
    }
    try {
      ProviderScope.containerOf(context, listen: false);
    } catch (_) {
      return builder(const SizedBox.shrink(), (_, _, original) => original);
    }
    return _ConnectedTranslationHost(
      conversationId: conversationId!,
      messageId: messageId!,
      segments: segments,
      isStreaming: isStreaming,
      expanded: expanded,
      builder: builder,
    );
  }
}

class _ConnectedTranslationHost extends ConsumerStatefulWidget {
  const _ConnectedTranslationHost({
    required this.conversationId,
    required this.messageId,
    required this.segments,
    required this.isStreaming,
    required this.expanded,
    required this.builder,
  });
  final String conversationId, messageId;
  final List<String> segments;
  final bool isStreaming, expanded;
  final ReasoningTranslationBuilder builder;
  @override
  ConsumerState<_ConnectedTranslationHost> createState() =>
      _ConnectedTranslationHostState();
}

class _ConnectedTranslationHostState
    extends ConsumerState<_ConnectedTranslationHost> {
  late final ReasoningTranslation _translator;
  bool _syncScheduled = false;
  String get _key =>
      ReasoningTranslation.key(widget.conversationId, widget.messageId);
  @override
  void initState() {
    super.initState();
    _translator = ref.read(reasoningTranslationProvider.notifier);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(_ConnectedTranslationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId ||
        oldWidget.messageId != widget.messageId) {
      _translator.setVisible(
        oldWidget.conversationId,
        oldWidget.messageId,
        false,
      );
    }
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      _translator.setVisible(
        widget.conversationId,
        widget.messageId,
        widget.expanded,
      );
      _translator.updateSource(
        conversationId: widget.conversationId,
        messageId: widget.messageId,
        segments: widget.segments,
        isStreaming: widget.isStreaming,
      );
    });
  }

  @override
  void dispose() {
    _translator.setVisible(widget.conversationId, widget.messageId, false);
    super.dispose();
  }

  Future<void> _chooseModel(
    BuildContext anchor,
    _TranslationPreferences preferences,
  ) async {
    final settings = ref.read(settingsControllerProvider).value;
    if (settings == null) return;
    final models = serviceModelCatalog(settings.profiles);
    final selected = await showComposerPopover<String>(
      anchor,
      width: 380,
      builder: (_) =>
          _TranslationModels(models: models, selected: preferences.model),
    );
    if (selected == null || !mounted || selected == preferences.model) return;
    // Selecting a model doesn't buy a translation; wait for the explicit action.
    _translator.stop(widget.conversationId, widget.messageId);
    ref
        .read(_translationPreferencesProvider.notifier)
        .save(
          _key,
          _TranslationPreferences(model: selected, view: preferences.view),
        );
  }

  @override
  Widget build(BuildContext context) {
    final translation = ref.watch(reasoningTranslationProvider)[_key];
    final preferences =
        ref.watch(_translationPreferencesProvider)[_key] ??
        _TranslationPreferences(model: translation?.modelChoice ?? '');
    final settings = ref.watch(settingsControllerProvider).value;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final matchesModel = translation?.modelChoice == preferences.model;
    final translationError = matchesModel ? translation?.error : null;
    final busy = matchesModel && (translation?.isRunning ?? false);
    final complete =
        translation != null &&
        translation.modelChoice == preferences.model &&
        widget.segments.indexed.every(
          (entry) =>
              translation.textFor(entry.$1, entry.$2) != null &&
              (translation.translatedSourceLengths[entry.$1] ?? 0) >=
                  entry.$2.length,
        );
    final activeTranslation =
        matchesModel &&
        translation?.enabled == true &&
        translationError == null &&
        (busy || widget.isStreaming || !complete);
    void saveView(ReasoningTranslationView view) => ref
        .read(_translationPreferencesProvider.notifier)
        .save(
          _key,
          _TranslationPreferences(model: preferences.model, view: view),
        );
    void translate() {
      saveView(ReasoningTranslationView.chinese);
      _translator.setVisible(
        widget.conversationId,
        widget.messageId,
        widget.expanded,
      );
      _translator.start(
        conversationId: widget.conversationId,
        messageId: widget.messageId,
        segments: widget.segments,
        isStreaming: widget.isStreaming,
        modelChoice: preferences.model,
      );
    }

    final controls = !widget.expanded
        ? const SizedBox.shrink()
        : Padding(
            key: const ValueKey('thinking-translation-controls'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Builder(
                      builder: (anchor) => Tooltip(
                        message: preferences.model.isEmpty
                            ? '翻译使用当前会话模型，会额外消耗用量；不会更改工作模型'
                            : '翻译模型：${preferences.model}',
                        child: TextButton.icon(
                          key: const ValueKey('thinking-translation-model'),
                          onPressed: settings == null
                              ? null
                              : () => _chooseModel(anchor, preferences),
                          icon: const Icon(Icons.translate, size: 15),
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 190),
                            child: Text(
                              preferences.model.isEmpty
                                  ? '翻译模型 · 跟随当前'
                                  : preferences.model,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ),
                    PopupMenuButton<ReasoningTranslationView>(
                      tooltip: '思考显示方式',
                      initialValue: preferences.view,
                      onSelected: saveView,
                      itemBuilder: (_) => [
                        for (final view in ReasoningTranslationView.values)
                          CheckedPopupMenuItem(
                            value: view,
                            checked: view == preferences.view,
                            child: Text(_viewName(view)),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _viewName(preferences.view),
                              style: theme.textTheme.labelMedium,
                            ),
                            const Icon(Icons.expand_more, size: 16),
                          ],
                        ),
                      ),
                    ),
                    if (activeTranslation) ...[
                      if (busy)
                        const SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      else
                        Text(
                          widget.isStreaming ? '等待新片段' : '准备翻译',
                          style: theme.textTheme.labelSmall,
                        ),
                      TextButton(
                        onPressed: () => _translator.stop(
                          widget.conversationId,
                          widget.messageId,
                        ),
                        child: const Text('停止翻译'),
                      ),
                    ] else
                      TextButton.icon(
                        key: const ValueKey('thinking-translate-start'),
                        onPressed:
                            settings == null ||
                                (complete && translationError == null)
                            ? null
                            : translate,
                        icon: const Icon(Icons.translate, size: 15),
                        label: Text(
                          translationError != null
                              ? '重试翻译'
                              : complete
                              ? '译文已就绪'
                              : '翻译为中文',
                        ),
                      ),
                  ],
                ),
                if (translationError != null)
                  Text(
                    translationError,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                if (translation != null && translation.requestCount > 0)
                  Text(
                    [
                      if (translation.actualModel.isNotEmpty)
                        matchesModel
                            ? translation.actualModel
                            : '上次使用 ${translation.actualModel}',
                      '累计翻译 ${translation.requestCount} 次',
                      translation.reportedUsageCount == 0
                          ? '用量未提供'
                          : '${translation.reportedUsageCount < translation.requestCount ? '已知用量 ' : ''}输入 ${translation.inputTokens} / 输出 ${translation.outputTokens} token',
                      if (translation.cost != null &&
                          translation.currency?.isNotEmpty == true)
                        '已知费用 ${translation.currency} ${translation.cost!.toStringAsFixed(4)}',
                    ].join(' · '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          );
    Widget render(int index, String source, Widget original) {
      if (preferences.view == ReasoningTranslationView.original ||
          translation == null ||
          translation.modelChoice != preferences.model) {
        return original;
      }
      final checked = translation.textFor(index, source);
      final translated = translation.translatedSegments[index];
      if (checked == null || translated == null || translated.isEmpty) {
        return original;
      }
      final translatedLength = (translation.translatedSourceLengths[index] ?? 0)
          .clamp(0, source.length);
      final pending = source.substring(translatedLength);
      final translatedWidget = Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(
              translated,
              key: ValueKey('thinking-translated-segment-$index'),
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.65,
                color: colors.onSurfaceVariant,
              ),
            ),
            if (pending.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '待翻译原文',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.outline,
                ),
              ),
              SelectableText(
                pending,
                key: ValueKey('thinking-untranslated-tail-$index'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.65,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );
      if (preferences.view == ReasoningTranslationView.chinese) {
        return translatedWidget;
      }
      Widget labeled(String label, Widget content) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: colors.primary),
          ),
          content,
        ],
      );
      return LayoutBuilder(
        builder: (context, size) {
          if (size.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                labeled('原文', original),
                const SizedBox(height: 6),
                labeled('中文', translatedWidget),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: labeled('原文', original)),
              const SizedBox(width: 18),
              Expanded(child: labeled('中文', translatedWidget)),
            ],
          );
        },
      );
    }

    return widget.builder(controls, render);
  }

  String _viewName(ReasoningTranslationView view) => switch (view) {
    ReasoningTranslationView.original => '原文',
    ReasoningTranslationView.chinese => '中文',
    ReasoningTranslationView.comparison => '对照',
  };
}

class _TranslationModels extends StatefulWidget {
  const _TranslationModels({required this.models, required this.selected});
  final List<String> models;
  final String selected;
  @override
  State<_TranslationModels> createState() => _TranslationModelsState();
}

class _TranslationModelsState extends State<_TranslationModels> {
  String _query = '';
  @override
  Widget build(BuildContext context) => ComposerPopoverFrame(
    title: '选择思考翻译模型',
    body: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: '搜索模型',
          ),
          onChanged: (value) => setState(() => _query = value.toLowerCase()),
        ),
        ListTile(
          dense: true,
          title: const Text('跟随当前会话模型'),
          selected: widget.selected.isEmpty,
          onTap: () => Navigator.pop(context, ''),
        ),
        for (final model in widget.models.where(
          (model) => model.toLowerCase().contains(_query),
        ))
          ListTile(
            dense: true,
            title: Text(model),
            selected: widget.selected == model,
            onTap: () => Navigator.pop(context, model),
          ),
      ],
    ),
  );
}
