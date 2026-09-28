import 'package:flutter/material.dart';

import '../../../data/ui_prefs.dart';
import '../../chat/widgets/previewable_code_block.dart';
import '../../chat/widgets/streaming_markdown.dart';

class ColorThemeLivePreview extends StatelessWidget {
  const ColorThemeLivePreview({
    super.key,
    required this.theme,
    required this.themeMode,
  });

  final ColorThemePref theme;
  final ThemeMode themeMode;

  bool _preferDark(BuildContext context) {
    return switch (themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
  }

  @override
  Widget build(BuildContext context) {
    final seed = Color(theme.previewArgb);
    final accent = Color(theme.accentPreviewArgb);
    final dark = _preferDark(context);
    final surface = dark
        ? Color.lerp(const Color(0xFF121418), seed, 0.18)!
        : Color.lerp(const Color(0xFFF7F5F1), seed, 0.08)!;
    final panel = dark
        ? Color.lerp(surface, Colors.white, 0.06)!
        : Color.lerp(surface, Colors.white, 0.55)!;
    final ink = dark ? const Color(0xFFE8EEF5) : const Color(0xFF1C2430);
    final muted = ink.withValues(alpha: 0.55);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: seed.withValues(alpha: dark ? 0.35 : 0.22)),
        boxShadow: [
          BoxShadow(
            color: seed.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: seed, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '预览 · ${theme.label}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
              Text(
                dark ? '深色' : '浅色',
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 260),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: panel,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                ),
                border: Border.all(color: seed.withValues(alpha: 0.12)),
              ),
              child: Text(
                '你好，我是助手。这是「${theme.label}」配色下的气泡样式。',
                style: TextStyle(fontSize: 12.5, height: 1.4, color: ink),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: seed,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: const Text(
                '看起来不错，就用这套。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _PreviewChip(color: seed, label: '主色'),
              const SizedBox(width: 8),
              _PreviewChip(color: accent, label: '强调'),
              const Spacer(),
              Text(
                theme.description,
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Visual grid of curated color themes.
class ColorThemePicker extends StatelessWidget {
  const ColorThemePicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final ColorThemePref selected;
  final ValueChanged<ColorThemePref> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cross = width >= 900
            ? 5
            : width >= 680
            ? 4
            : width >= 420
            ? 3
            : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: ColorThemePref.values.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.92,
          ),
          itemBuilder: (context, index) {
            final theme = ColorThemePref.values[index];
            final isOn = theme == selected;
            final seed = Color(theme.previewArgb);
            final accent = Color(theme.accentPreviewArgb);
            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onSelected(theme),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isOn
                          ? seed
                          : scheme.outlineVariant.withValues(alpha: 0.85),
                      width: isOn ? 2 : 1,
                    ),
                    boxShadow: isOn
                        ? [
                            BoxShadow(
                              color: seed.withValues(alpha: 0.22),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 5,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    seed,
                                    Color.lerp(seed, accent, 0.55)!,
                                    accent,
                                  ],
                                  stops: const [0, 0.55, 1],
                                ),
                              ),
                            ),
                            // Soft paper wash so labels stay legible on neon seeds.
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                height: 28,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withValues(alpha: 0),
                                      Colors.black.withValues(alpha: 0.18),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (isOn)
                              const Positioned(
                                top: 8,
                                right: 8,
                                child: _SelectedBadge(),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                theme.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: isOn ? seed : scheme.onSurface,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Expanded(
                                child: Text(
                                  theme.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        height: 1.2,
                                      ),
                                ),
                              ),
                              Row(
                                children: [
                                  _Dot(color: seed),
                                  const SizedBox(width: 4),
                                  _Dot(color: accent),
                                  const Spacer(),
                                  if (theme == ColorThemePref.minimal)
                                    Text(
                                      '默认',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: const Icon(
        Icons.check_rounded,
        size: 14,
        color: Color(0xFF1C2430),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.7),
          width: 0.8,
        ),
      ),
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
