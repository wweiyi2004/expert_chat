import 'package:flutter/material.dart';

import '../../../data/models.dart';

/// Collapsible panel above the answer showing what the web-search flow did,
/// step by step ("搜索 X → 8 条结果"、"读取 example.com"), live while the
/// request runs and preserved in history afterwards. Mirrors [ThinkingPanel]'s
/// look so the two stack naturally.
class SearchActivityPanel extends StatefulWidget {
  const SearchActivityPanel({
    super.key,
    required this.activities,
    required this.isStreaming,
  });

  final List<SearchActivity> activities;

  /// Whether the owning message is still being generated (drives the live
  /// pulse; once false, `running` steps render as interrupted).
  final bool isStreaming;

  @override
  State<SearchActivityPanel> createState() => _SearchActivityPanelState();
}

class _SearchActivityPanelState extends State<SearchActivityPanel>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  bool _userToggled = false;
  late final AnimationController _pulse;

  bool get _active =>
      widget.isStreaming &&
      widget.activities.any((a) => a.status == SearchActivityStatus.running);

  @override
  void initState() {
    super.initState();
    _expanded = _active;
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (_active) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(SearchActivityPanel old) {
    super.didUpdateWidget(old);
    final active = _active;
    if (_pulse.isAnimating && !active) {
      _pulse.stop();
      if (!_userToggled) setState(() => _expanded = false);
    } else if (!_pulse.isAnimating && active) {
      _pulse.repeat(reverse: true);
      if (!_userToggled) setState(() => _expanded = true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  int get _sourceCount =>
      widget.activities.fold(0, (sum, a) => sum + a.resultCount);

  String get _label {
    if (_active) {
      final running = widget.activities.lastWhere(
        (a) => a.status == SearchActivityStatus.running,
        orElse: () => widget.activities.last,
      );
      return running.kind == SearchActivityKind.fetch
          ? '正在读取网页…'
          : '正在搜索：${running.query}';
    }
    final sources = _sourceCount;
    if (sources > 0) return '已联网搜索 · $sources 个来源';
    if (widget.activities.any(
      (a) => a.status == SearchActivityStatus.failed,
    )) {
      return '联网搜索未获得可用结果';
    }
    return '已联网搜索';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() {
              _expanded = !_expanded;
              _userToggled = true;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  _active
                      ? FadeTransition(
                          opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
                          child: Icon(
                            Icons.travel_explore,
                            size: 18,
                            color: scheme.tertiary,
                          ),
                        )
                      : Icon(
                          Icons.travel_explore_outlined,
                          size: 18,
                          color: scheme.tertiary,
                        ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final a in widget.activities)
                    _ActivityRow(
                      activity: a,
                      showSpinner:
                          widget.isStreaming &&
                          a.status == SearchActivityStatus.running,
                    ),
                ],
              ),
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
          ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.activity, required this.showSpinner});

  final SearchActivity activity;
  final bool showSpinner;

  String get _text {
    final a = activity;
    final target = a.kind == SearchActivityKind.fetch
        ? _shortUrl(a.query)
        : a.query;
    return switch (a.status) {
      SearchActivityStatus.running =>
        showSpinner
            ? (a.kind == SearchActivityKind.fetch
                  ? '正在读取 $target'
                  : '正在搜索：$target')
            : (a.kind == SearchActivityKind.fetch
                  ? '读取中断：$target'
                  : '搜索中断：$target'),
      SearchActivityStatus.done =>
        a.kind == SearchActivityKind.fetch
            ? '已读取 $target'
            : '搜索"$target"：${a.resultCount} 条结果',
      SearchActivityStatus.failed =>
        a.kind == SearchActivityKind.fetch
            ? '读取失败 $target${a.error == null ? '' : '（${a.error}）'}'
            : '搜索"$target"失败${a.error == null ? '' : '：${a.error}'}',
    };
  }

  /// Hosts read better than full URLs in a one-line step list.
  static String _shortUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    final host = uri?.host ?? '';
    return host.isEmpty ? url : host;
  }

  IconData get _icon => switch (activity.kind) {
    SearchActivityKind.search => Icons.search,
    SearchActivityKind.fetch => Icons.public,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = activity.status == SearchActivityStatus.failed;
    final color = failed
        ? scheme.error.withValues(alpha: 0.85)
        : scheme.onSurfaceVariant.withValues(alpha: 0.88);

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSpinner)
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.tertiary,
              ),
            )
          else
            Icon(_icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _text,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
