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
    this.onAnswerFromResults,
    this.onRetryStep,
    this.onStop,
  });

  final String reasoning;
  final bool isStreaming;
  final int thinkingMillis;
  final List<SearchActivity> activities;
  final ValueChanged<bool>? onExpandedChanged;
  final VoidCallback? onAnswerFromResults;
  final ValueChanged<SearchActivity>? onRetryStep;
  final VoidCallback? onStop;

  @override
  State<ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<ThinkingPanel>
    with SingleTickerProviderStateMixin {
  bool _expanded = true;
  bool _userToggled = false;
  late final AnimationController _pulse;
  final _timelineScroll = ScrollController();
  bool _followTimeline = true;
  bool _followScheduled = false;

  bool get _toolRunning =>
      widget.isStreaming &&
      widget.activities.any((a) => a.status == SearchActivityStatus.running);

  @override
  void initState() {
    super.initState();
    _expanded = widget.activities.isNotEmpty;
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.isStreaming) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(ThinkingPanel old) {
    super.didUpdateWidget(old);
    if (!_userToggled && widget.activities.isNotEmpty) _expanded = true;
    if (_followTimeline && !_followScheduled && widget.isStreaming) {
      _followScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _followScheduled = false;
        if (!mounted || !_timelineScroll.hasClients || !_followTimeline) return;
        _timelineScroll.animateTo(
          _timelineScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      });
    }
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
    _timelineScroll.dispose();
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
      return widget.activities.isNotEmpty ? '正在整理答复…' : '正在思考…';
    }
    if (widget.activities.isNotEmpty) {
      final done = widget.activities
          .where((a) => a.status == SearchActivityStatus.done)
          .length;
      final incomplete = widget.activities.length - done;
      return incomplete > 0
          ? '处理记录 · $done 步完成 · $incomplete 步未完成'
          : '处理完成 · $done 个步骤';
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
            key: const ValueKey('thinking-panel-toggle'),
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
            firstChild:
                !_expanded && widget.isStreaming && widget.reasoning.isNotEmpty
                ? _CollapsedReasoningPreview(text: widget.reasoning)
                : const SizedBox(width: double.infinity, height: 0),
            secondChild: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.48,
              ),
              child: NotificationListener<UserScrollNotification>(
                onNotification: (n) {
                  _followTimeline = n.metrics.extentAfter <= 12;
                  return false;
                },
                child: Scrollbar(
                  controller: _timelineScroll,
                  child: SingleChildScrollView(
                    key: const ValueKey('thinking-timeline-scroll'),
                    controller: _timelineScroll,
                    primary: false,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(color: scheme.outlineVariant),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final segment in segments)
                                if (segment.isReasoning)
                                  _ReasoningQuote(text: segment.text!)
                                else
                                  _ToolStepNode(
                                    activity: segment.activity!,
                                    onRetry:
                                        widget.onRetryStep == null ||
                                            widget.activities.any(
                                              (a) =>
                                                  a.retryOfId ==
                                                      segment.activity!.id &&
                                                  a.status ==
                                                      SearchActivityStatus.done,
                                            )
                                        ? null
                                        : () => widget.onRetryStep!(
                                            segment.activity!,
                                          ),
                                    showSpinner:
                                        widget.isStreaming &&
                                        segment.activity!.status ==
                                            SearchActivityStatus.running,
                                  ),
                              if (widget.onAnswerFromResults != null ||
                                  widget.onStop != null)
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    if (widget.onAnswerFromResults != null)
                                      TextButton.icon(
                                        onPressed: widget.onAnswerFromResults,
                                        icon: const Icon(Icons.done, size: 16),
                                        label: const Text('用已有资料回答'),
                                      ),
                                    if (widget.onStop != null)
                                      TextButton.icon(
                                        onPressed: widget.onStop,
                                        icon: const Icon(
                                          Icons.stop_circle_outlined,
                                          size: 16,
                                        ),
                                        label: const Text('停止任务'),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
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

/// A short live viewport keeps the latest thought visible after folding the
/// full timeline. Its scroll is local to the panel, so it never moves the chat.
class _CollapsedReasoningPreview extends StatefulWidget {
  const _CollapsedReasoningPreview({required this.text});

  final String text;

  @override
  State<_CollapsedReasoningPreview> createState() =>
      _CollapsedReasoningPreviewState();
}

class _CollapsedReasoningPreviewState
    extends State<_CollapsedReasoningPreview> {
  final _scroll = ScrollController();
  bool _followScheduled = false;
  bool _followTail = true;

  @override
  void initState() {
    super.initState();
    _scheduleFollow(initial: true);
  }

  @override
  void didUpdateWidget(_CollapsedReasoningPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) _scheduleFollow();
  }

  void _scheduleFollow({bool initial = false}) {
    if (_followScheduled || !_followTail) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_scroll.hasClients || !_followTail) return;
      final end = _scroll.position.maxScrollExtent;
      if (initial || MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var start = widget.text.length > 1000 ? widget.text.length - 1000 : 0;
    if (start > 0 &&
        widget.text.codeUnitAt(start) >= 0xDC00 &&
        widget.text.codeUnitAt(start) <= 0xDFFF) {
      start--;
    }
    final scheme = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    return Padding(
      key: const ValueKey('thinking-collapsed-preview'),
      padding: const EdgeInsets.only(top: 4, bottom: 4, left: 12),
      child: SizedBox(
        height: 13 * 1.65 * scale * 5,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: [0, 0.10, 0.88, 1],
          ).createShader(bounds),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is UserScrollNotification) {
                _followTail = notification.metrics.extentAfter <= 4;
              }
              return false;
            },
            child: SingleChildScrollView(
              key: const ValueKey('thinking-collapsed-scroll'),
              controller: _scroll,
              child: Text(
                widget.text.substring(start),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.65,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReasoningQuote extends StatefulWidget {
  const _ReasoningQuote({required this.text});

  final String text;

  @override
  State<_ReasoningQuote> createState() => _ReasoningQuoteState();
}

class _ReasoningQuoteState extends State<_ReasoningQuote> {
  bool _showAll = false;
  static const _previewChars = 1000;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clipped = !_showAll && widget.text.length > _previewChars;
    var start = clipped ? widget.text.length - _previewChars : 0;
    if (start > 0 &&
        widget.text.codeUnitAt(start) >= 0xDC00 &&
        widget.text.codeUnitAt(start) <= 0xDFFF) {
      start--;
    }
    final text = widget.text.substring(start);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(width: 3, color: scheme.outlineVariant),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.text.length > _previewChars)
                TextButton(
                  onPressed: () => setState(() => _showAll = !_showAll),
                  child: Text(
                    _showAll ? '收起完整思考' : '展开完整思考（${widget.text.length} 字）',
                  ),
                ),
              SelectableText(
                text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.65,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.92),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolStepNode extends StatefulWidget {
  const _ToolStepNode({
    required this.activity,
    required this.showSpinner,
    this.onRetry,
  });

  final SearchActivity activity;
  final bool showSpinner;
  final VoidCallback? onRetry;

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
                  activity.status == SearchActivityStatus.running
                      ? (widget.showSpinner
                            ? activity.kind.runningLabel(activity.query)
                            : '已中断：${activity.query}')
                      : activity.kind.summary(activity),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          if (activity.query.isNotEmpty &&
              (activity.kind == SearchActivityKind.search ||
                  activity.kind == SearchActivityKind.fetch))
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 3),
              child: Text(
                activity.query,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          if (activity.finishedAt != null && activity.startedAt != null)
            Text(
              '耗时 ${(activity.finishedAt!.difference(activity.startedAt!).inMilliseconds.clamp(0, 86400000) / 1000).toStringAsFixed(1)} 秒',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (failed && activity.error != null)
            Text(
              activity.error!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          if (failed && !activity.canRetry)
            Text(
              '此步骤没有可安全恢复的参数；请检查原因后重新发起任务。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Wrap(
            spacing: 8,
            children: [
              if (activity.canRetry && widget.onRetry != null)
                TextButton(
                  onPressed: widget.onRetry,
                  child: const Text('仅重试此步骤'),
                ),
              if (activity.resultText?.isNotEmpty ?? false)
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (dialog) => AlertDialog(
                      title: const Text('步骤结果'),
                      content: SizedBox(
                        width: 600,
                        child: SingleChildScrollView(
                          child: SelectableText(activity.resultText!),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialog),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('查看结果'),
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
    return Tooltip(
      message: item.title,
      child: ActionChip(
        visualDensity: VisualDensity.compact,
        avatar: const Icon(Icons.public_outlined, size: 14),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(
            item.title.isEmpty ? host : item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        onPressed: item.url.isEmpty ? null : () => _openUrl(item.url),
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
        constraints: const BoxConstraints(maxWidth: 160),
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
    SearchActivityKind.image => switch (query) {
      '优化提示词' => '正在优化生图提示词…',
      '准备参考图' => '正在准备参考图…',
      _ => '正在生成图片…',
    },
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
      SearchActivityKind.image => switch (activity.query) {
        '优化提示词' => '生图提示词已就绪',
        '准备参考图' => '参考图已就绪',
        _ => '已生成图片',
      },
      SearchActivityKind.document => switch (activity.query) {
        'inspect_document' => '已检查文档',
        'edit_document' => '已编辑文档',
        'convert_document' => '已转换文档',
        _ => '已处理文档',
      },
    };
  }
}
