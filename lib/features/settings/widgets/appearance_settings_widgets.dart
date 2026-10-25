import 'package:flutter/material.dart';

import '../../../data/ui_prefs.dart';
import '../../../core/theme.dart';
import '../../../core/prototype_widgets.dart';
import '../../chat/widgets/previewable_code_block.dart';
import '../../chat/widgets/streaming_markdown.dart';

/// A compact, truthful theme sample instead of an unrelated mock chat card.
class ColorThemeLivePreview extends StatelessWidget {
  const ColorThemeLivePreview({
    super.key,
    required this.theme,
    required this.themeMode,
  });
  final ColorThemePref theme;
  final ThemeMode themeMode;
  @override
  Widget build(BuildContext context) {
    final dark =
        themeMode == ThemeMode.dark ||
        themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final colors =
        (dark
                ? AppTheme.dark(UiPrefs(colorTheme: theme))
                : AppTheme.light(UiPrefs(colorTheme: theme)))
            .colorScheme;
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        '当前${dark ? '深色' : '浅色'} · ${theme.label} · 正文 ${contrast(colors.onSurface, colors.surface).toStringAsFixed(1)}:1 · 主按钮 ${contrast(colors.onPrimary, colors.primary).toStringAsFixed(1)}:1',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 11.5,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class ColorThemePicker extends StatelessWidget {
  const ColorThemePicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });
  final ColorThemePref selected;
  final ValueChanged<ColorThemePref> onSelected;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _group(
        context,
        '艺术配色（中国传统色、和田三造《配色辞典》）',
        ColorThemePref.values.where((p) => p.isArt).toList(),
      ),
      const SizedBox(height: 16),
      _group(
        context,
        '原有配色（14 套）',
        ColorThemePref.values.where((p) => !p.isArt).toList(),
      ),
    ],
  );
  Widget _group(
    BuildContext context,
    String title,
    List<ColorThemePref> palettes,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontSize: 11.5,
            color: PrototypeColors.of(context).faint,
          ),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = ((constraints.maxWidth + 8) / 140).floor().clamp(
              1,
              6,
            );
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: palettes.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                mainAxisExtent:
                    88 *
                    MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4),
              ),
              itemBuilder: (context, index) {
                final palette = palettes[index];
                final active = palette == selected;
                return Semantics(
                  selected: active,
                  button: true,
                  child: Material(
                    color: scheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: active
                            ? scheme.primary
                            : PrototypeColors.of(context).line,
                        width: 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => onSelected(palette),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              height: 16,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(5),
                                child: Row(
                                  children: [
                                    for (final argb in palette.sourceColors)
                                      Expanded(
                                        child: ColoredBox(
                                          color: Color(argb),
                                          child: const SizedBox.expand(),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    palette.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(fontSize: 12.5),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Expanded(
                              child: Text(
                                palette.isArt
                                    ? palette.source
                                    : palette.description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 11,
                                    ),
                              ),
                            ),
                            if (palette == ColorThemePref.minimal)
                              Text(
                                '默认',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class MarkdownStylePreview extends StatelessWidget {
  const MarkdownStylePreview({super.key, required this.style});

  final MarkdownStylePref style;

  static const _sample = '''
# 标题
一段正文，内含 `inline code` 与 [链接](https://example.com)。

| 列 A | 列 B |
| :--- | ---: |
| 左 | 右 |
''';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: StreamingGptMarkdown(
          _sample,
          markdownStyle: style,
          codeBuilder: (context, name, code, closed) => PreviewableCodeBlock(
            name: name,
            code: code,
            closed: closed,
            markdownStyle: style,
          ),
        ),
      ),
    );
  }
}
