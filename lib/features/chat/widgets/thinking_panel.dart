import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/models.dart';
import '../../../domain/chat/thinking_timeline.dart';

/// Collapsible DeepSeek-style thinking chain: prose with a left bar, tool
/// steps (search / browse / MCP / image) inlined as chips.
class ThinkingPanel extends StatefulWidget {
  const ThinkingPanel({
    super.key,
    required this.reasoning,
    required this.isStreaming,
    this.thinkingMillis = 0,
    this.activities = const [],
    this.onExpandedChanged,
  });

  final String reasoning;
  final bool isStreaming;
  final int thinkingMillis;
  final List<SearchActivity> activities;
  final ValueChanged<bool>? onExpandedChanged;

  @override
  State<ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<ThinkingPanel>
    with SingleTickerProviderStateMixin {
  bool _expanded = true;
  bool _userToggled = false;
  late final AnimationController _pulse;

  bool get _toolRunning =>
      widget.isStreaming &&
      widget.activities.any((a) => a.status == SearchActivityStatus.running);

  @override
  void initState() {
    super.initState();
    _expanded = widget.isStreaming || widget.activities.isNotEmpty;
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.isStreaming) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(ThinkingPanel old) {
    super.didUpdateWidget(old);
    if (old.isStreaming && !widget.isStreaming) {
      _pulse.stop();
      // Keep tool traces visible; collapse only a bare reasoning dump.
      if (!_userToggled && widget.activities.isEmpty) {
        setState(() => _expanded = false);
        widget.onExpandedChanged?.call(false);
      }
    } else if (!old.isStreaming && widget.isStreaming) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  String get _label {
    if (widget.isStreaming) {
      if (_toolRunning) {
        final running = widget.activities.lastWhere(
          (a) => a.status == SearchActivityStatus.running,
          orElse: () => widget.activities.last,
        );
        return running.kind.runningLabel(running.query);
      }
      return '正在思考…';
    }
    final secs = (widget.thinkingMillis / 1000).round();
    if (secs <= 0) return '已思考';
    return '已思考 (用时 $secs 秒)';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final segments = buildThinkingTimeline(
      reasoning: widget.reasoning,
      activities: widget.activities,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              setState(() {
                _expanded = !_expanded;
                _userToggled = true;
              });
              widget.onExpandedChanged?.call(_expanded);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  widget.isStreaming
                      ? FadeTransition(
                          opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
                          child: Icon(
                            Icons.auto_awesome,
                            size: 16,
                            color: scheme.primary,
                          ),
                        )
                      : Icon(
                          Icons.auto_awesome,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                  const SizedBox(width: 6),
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
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
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
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final segment in segments)
                    if (segment.isReasoning)
                      _ReasoningQuote(text: segment.text!)
                    else
                      _ToolStepNode(
                        activity: segment.activity!,
                        showSpinner:
                            widget.isStreaming &&
                            segment.activity!.status ==
                                SearchActivityStatus.running,
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

class _ReasoningQuote extends StatelessWidget {
  const _ReasoningQuote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 3,
              margin: const EdgeInsets.only(right: 10, top: 2, bottom: 2),
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Expanded(
              child: SelectableText(
                text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.65,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.92),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolStepNode extends StatefulWidget {
  const _ToolStepNode({required this.activity, required this.showSpinner});

  final SearchActivity activity;
  final bool showSpinner;

  @override
  State<_ToolStepNode> createState() => _ToolStepNodeState();
}

class _ToolStepNodeState extends State<_ToolStepNode> {
  bool _showAll = false;

  static const _previewCount = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activity = widget.activity;
    final failed = activity.status == SearchActivityStatus.failed;
    final color = failed ? scheme.error : scheme.onSurface;
    final items = activity.items;
    final visible = _showAll || items.length <= _previewCount
        ? items
        : items.take(_previewCount).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.showSpinner)
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                )
              else
                Icon(activity.kind.icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  activity.kind.summary(activity),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          if (visible.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final item in visible)
                  activity.kind == SearchActivityKind.search
                      ? _FaviconChip(item: item)
                      : _TitleChip(item: item),
                if (!_showAll && items.length > _previewCount)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: const Text('查看全部'),
                    onPressed: () => setState(() => _showAll = true),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FaviconChip extends StatelessWidget {
  const _FaviconChip({required this.item});

  final SearchActivityItem item;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(item.url)?.host ?? '';
    final letter =
        (host.isNotEmpty
                ? host[0]
                : (item.title.isNotEmpty ? item.title[0] : '?'))
            .toUpperCase();
    return Tooltip(
      message: item.title,
      child: InkWell(
        onTap: item.url.isEmpty ? null : () => _openUrl(item.url),
        customBorder: const CircleBorder(),
        child: CircleAvatar(
          radius: 10,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest,
          backgroundImage: host.isEmpty
              ? null
              : NetworkImage(
                  'https://www.google.com/s2/favicons?domain=$host&sz=32',
                ),
          onBackgroundImageError: host.isEmpty ? null : (_, _) {},
          child: host.isEmpty
              ? Text(letter, style: const TextStyle(fontSize: 10))
              : null,
        ),
      ),
    );
  }
}

class _TitleChip extends StatelessWidget {
  const _TitleChip({required this.item});

  final SearchActivityItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.open_in_new, size: 14, color: scheme.onSurfaceVariant),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Text(
          item.title.isEmpty ? item.url : item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      onPressed: item.url.isEmpty ? null : () => _openUrl(item.url),
    );
  }
}

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  final scheme = uri?.scheme.toLowerCase();
  if (uri == null ||
      uri.host.isEmpty ||
      (scheme != 'https' && scheme != 'http')) {
    return;
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

extension on SearchActivityKind {
  IconData get icon => switch (this) {
    SearchActivityKind.search => Icons.search,
    SearchActivityKind.fetch => Icons.article_outlined,
    SearchActivityKind.vision => Icons.visibility_outlined,
    SearchActivityKind.mcp => Icons.extension_outlined,
    SearchActivityKind.image => Icons.image_outlined,
    SearchActivityKind.document => Icons.edit_document,
  };

  String runningLabel(String query) => switch (this) {
    SearchActivityKind.search => '正在搜索…',
    SearchActivityKind.fetch => '正在浏览页面…',
    SearchActivityKind.vision => '正在识图…',
    SearchActivityKind.mcp => '正在调用 $query…',
    SearchActivityKind.image => '正在生成图片…',
    SearchActivityKind.document => switch (query) {
      'inspect_document' => '正在检查文档…',
      'edit_document' => '正在编辑文档…',
      'convert_document' => '正在转换文档…',
      _ => '正在处理文档…',
    },
  };

  String summary(SearchActivity activity) {
    if (activity.status == SearchActivityStatus.failed) {
      final err = activity.error;
      return err == null || err.isEmpty ? '未完成' : '失败：$err';
    }
    final n = activity.resultCount;
    return switch (this) {
      SearchActivityKind.search => n > 0 ? '搜索到 $n 个网页' : '已搜索',
      SearchActivityKind.fetch => n > 0 ? '浏览 $n 个页面' : '已浏览页面',
      SearchActivityKind.vision => '已识图',
      SearchActivityKind.mcp => '已调用 ${activity.query}',
      SearchActivityKind.image => '已生成图片',
      SearchActivityKind.document => switch (activity.query) {
        'inspect_document' => '已检查文档',
        'edit_document' => '已编辑文档',
        'convert_document' => '已转换文档',
        _ => '已处理文档',
      },
    };
  }
}
