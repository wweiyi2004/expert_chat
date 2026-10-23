import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../data/ui_prefs.dart';
import '../../chat/widgets/streaming_markdown.dart';

class ReadingAppearanceSettings extends StatefulWidget {
  const ReadingAppearanceSettings({
    super.key,
    required this.prefs,
    required this.onChanged,
  });
  final UiPrefs prefs;
  final ValueChanged<UiPrefs> onChanged;
  @override
  State<ReadingAppearanceSettings> createState() =>
      _ReadingAppearanceSettingsState();
}

class _ReadingAppearanceSettingsState extends State<ReadingAppearanceSettings> {
  late UiPrefs _draft = widget.prefs;
  bool _dragging = false;
  @override
  void didUpdateWidget(covariant ReadingAppearanceSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging) _draft = widget.prefs;
  }

  void _save(UiPrefs value) {
    setState(() => _draft = value);
    widget.onChanged(value);
  }

  Widget _slider(
    String title,
    double value,
    double min,
    double max,
    int divisions,
    UiPrefs Function(double) change, {
    String? label,
    bool enabled = true,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(title)),
          Text(
            label ?? '${value.round()} px',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: label ?? '${value.round()} px',
        onChangeStart: enabled ? (_) => _dragging = true : null,
        onChanged: enabled ? (v) => setState(() => _draft = change(v)) : null,
        onChangeEnd: enabled
            ? (_) {
                _dragging = false;
                widget.onChanged(_draft);
              }
            : null,
      ),
    ],
  );
  Widget _choices<T>(
    String title,
    Iterable<T> values,
    T selected,
    String Function(T) label,
    UiPrefs Function(T) change,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final value in values)
              ChoiceChip(
                label: Text(label(value)),
                selected: selected == value,
                onSelected: (_) => _save(change(value)),
              ),
          ],
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('阅读排版', style: theme.textTheme.titleMedium)),
              TextButton(
                onPressed: () => _save(
                  _draft.copyWith(
                    lineHeight: 1.85,
                    paragraphSpacing: 8,
                    messageSpacing: 24,
                    adaptiveMessagePadding: true,
                    messagePadding: 32,
                    workMessageStyle: MessageStylePref.document,
                    workContentWidth: ContentWidthPref.full,
                    popoverMaxHeight: 420,
                    popoverTopMargin: 40,
                  ),
                ),
                child: const Text('恢复默认'),
              ),
            ],
          ),
          Text('拖动时预览，松手后自动保存并应用到回复。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Theme(
            data: theme.copyWith(extensions: [AppMetrics.fromPrefs(_draft)]),
            child: Builder(
              builder: (previewContext) => LayoutBuilder(
                builder: (context, constraints) {
                  final padding = _draft.horizontalMessagePadding(
                    constraints.maxWidth,
                  );
                  return Container(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: padding,
                      vertical: 16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '工作回复预览',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding:
                              _draft.workMessageStyle == MessageStylePref.bubble
                              ? const EdgeInsets.all(12)
                              : EdgeInsets.zero,
                          decoration:
                              _draft.workMessageStyle == MessageStylePref.bubble
                              ? BoxDecoration(
                                  color: colors.surfaceContainer,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: colors.outlineVariant,
                                  ),
                                )
                              : null,
                          child: StreamingGptMarkdown(
                            '正文会按设定的行距换行。读较长的分析、代码说明和工作报告时，可以适当调宽行距。\n\n这是第二段，用来观察段落之间的距离。',
                            markdownStyle: _draft.markdownStyle,
                          ),
                        ),
                        SizedBox(height: _draft.messageSpacing),
                        Text(
                          '下一条消息',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 18),
          _slider(
            '正文行距',
            _draft.lineHeight,
            1.2,
            2.4,
            24,
            (v) => _draft.copyWith(lineHeight: v),
            label: '${_draft.lineHeight.toStringAsFixed(2)} 倍',
          ),
          _slider(
            '段落间距',
            _draft.paragraphSpacing,
            0,
            24,
            12,
            (v) => _draft.copyWith(paragraphSpacing: v),
          ),
          _slider(
            '消息间距',
            _draft.messageSpacing,
            8,
            48,
            20,
            (v) => _draft.copyWith(messageSpacing: v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('左右留白自适应'),
            subtitle: const Text('跟随对话栏宽度，窄屏自动收紧'),
            value: _draft.adaptiveMessagePadding,
            onChanged: (v) => _save(_draft.copyWith(adaptiveMessagePadding: v)),
          ),
          _slider(
            '左右留白',
            _draft.messagePadding,
            12,
            72,
            15,
            (v) => _draft.copyWith(messagePadding: v),
            enabled: !_draft.adaptiveMessagePadding,
          ),
          _choices(
            '工作回复样式',
            MessageStylePref.values,
            _draft.workMessageStyle,
            (v) => v == MessageStylePref.document ? '无气泡' : '气泡',
            (v) => _draft.copyWith(workMessageStyle: v),
          ),
          _choices(
            '工作内容宽度',
            ContentWidthPref.values,
            _draft.workContentWidth,
            (v) => v.label,
            (v) => _draft.copyWith(workContentWidth: v),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('悬浮框尺寸'),
            children: [
              _slider(
                '最大高度',
                _draft.popoverMaxHeight,
                280,
                600,
                16,
                (v) => _draft.copyWith(popoverMaxHeight: v),
              ),
              _slider(
                '顶部留白',
                _draft.popoverTopMargin,
                16,
                64,
                12,
                (v) => _draft.copyWith(popoverTopMargin: v),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '模型、项目、文件和 MCP 弹层共用；屏幕空间不足时自动缩小。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
