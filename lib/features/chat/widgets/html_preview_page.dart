import 'package:expert_chat/core/app_toast.dart';
import 'preview_zoom_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/html/html_preview_sandbox.dart';
import '../../../domain/html/html_snippet.dart';
import 'html_preview_launcher_web.dart'
    if (dart.library.io) 'html_preview_launcher_io.dart';
import 'local_html_surface.dart';

/// Local preview workspace. Edits remain here and never rewrite chat history.
class HtmlPreviewPage extends StatefulWidget {
  const HtmlPreviewPage({
    super.key,
    required this.snippets,
    this.initialIndex = 0,
    this.surfaceBuilder,
  });
  final List<HtmlSnippet> snippets;
  final int initialIndex;
  final Widget Function(BuildContext, String)? surfaceBuilder;

  static Future<void> open(
    BuildContext context, {
    required List<HtmlSnippet> snippets,
    int initialIndex = 0,
  }) {
    if (snippets.isEmpty) return Future.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            HtmlPreviewPage(snippets: snippets, initialIndex: initialIndex),
      ),
    );
  }

  @override
  State<HtmlPreviewPage> createState() => _HtmlPreviewPageState();
}

class _HtmlPreviewPageState extends State<HtmlPreviewPage> {
  late int _index;
  late List<String> _drafts;
  late List<HtmlSnippet> _rendered;
  late TextEditingController _source;
  bool _editing = false;
  double? _zoom;
  bool _phoneWidth = false;
  double _deviceWidth = 390;
  int _revision = 0;
  String? _error;
  HtmlSnippet get _current => _rendered[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.snippets.length - 1);
    _drafts = [for (final snippet in widget.snippets) snippet.code];
    _rendered = List.of(widget.snippets);
    _source = TextEditingController(text: _drafts[_index]);
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  void _switch(int index) {
    _drafts[_index] = _source.text;
    setState(() {
      _index = index;
      _source.text = _drafts[index];
      _revision++;
      _error = null;
    });
  }

  void _run() {
    final snippet = previewSnippetForCode(
      widget.snippets[_index].language,
      _source.text,
    );
    if (snippet == null) {
      setState(() => _error = '请填写有效的 HTML 或完整的 SVG 代码。');
      return;
    }
    setState(() {
      _drafts[_index] = _source.text;
      _rendered[_index] = snippet;
      _revision++;
      _error = null;
      _editing = false;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _source.text));
    if (mounted) {
      AppToastMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制源码')));
    }
  }

  Future<void> _external() async {
    final snippet = previewSnippetForCode(
      widget.snippets[_index].language,
      _source.text,
    );
    if (snippet == null) {
      setState(() => _error = '请填写有效的 HTML 或完整的 SVG 代码。');
      return;
    }
    try {
      await launchHtmlPreview(
        buildSandboxedHtmlPreview(snippet.html),
        fileName: 'expert_chat_preview_$_index.html',
      );
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开浏览器，可复制源码后在本机查看。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      appBar: AppBar(
        title: Text('${_current.label} 本地预览', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '复制源码',
            onPressed: _copy,
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            tooltip: '在浏览器打开',
            onPressed: _external,
            icon: const Icon(Icons.open_in_browser),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('预览'),
                        icon: Icon(Icons.visibility_outlined, size: 18),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('源码'),
                        icon: Icon(Icons.code, size: 18),
                      ),
                    ],
                    selected: {_editing},
                    onSelectionChanged: (next) {
                      if (next.first) {
                        setState(() => _editing = true);
                      } else {
                        _run();
                      }
                    },
                  ),
                  if (!_editing)
                    PreviewZoomControl(
                      zoom: _zoom,
                      onChanged: (value) => setState(() => _zoom = value),
                    ),
                  if (compact)
                    IconButton.filledTonal(
                      key: const ValueKey('preview-run'),
                      tooltip: _editing ? '运行预览' : '刷新',
                      onPressed: _run,
                      icon: const Icon(Icons.refresh),
                    )
                  else
                    FilledButton.tonalIcon(
                      key: const ValueKey('preview-run'),
                      onPressed: _run,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(_editing ? '运行预览' : '刷新'),
                    ),
                  if (!_editing && !compact)
                    FilterChip(
                      key: const ValueKey('preview-phone-width'),
                      selected: _phoneWidth,
                      onSelected: (value) =>
                          setState(() => _phoneWidth = value),
                      label: const Text('手机宽度'),
                      avatar: const Icon(Icons.smartphone, size: 17),
                    ),
                  if (!_editing && _phoneWidth && !compact)
                    DropdownButton<double>(
                      key: const ValueKey('preview-device-width'),
                      value: _deviceWidth,
                      items: [
                        for (final width in [360.0, 390.0, 430.0])
                          DropdownMenuItem(
                            value: width,
                            child: Text('${width.toInt()} px'),
                          ),
                      ],
                      onChanged: (width) {
                        if (width != null) setState(() => _deviceWidth = width);
                      },
                    ),
                  if (widget.snippets.length > 1)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '上一页',
                          onPressed: _index == 0
                              ? null
                              : () => _switch(_index - 1),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Text('${_index + 1} / ${widget.snippets.length}'),
                        IconButton(
                          tooltip: '下一页',
                          onPressed: _index == widget.snippets.length - 1
                              ? null
                              : () => _switch(_index + 1),
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            const Divider(height: 1),
            Expanded(
              child: _editing
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        key: const ValueKey('preview-source'),
                        controller: _source,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.5,
                        ),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: '粘贴 HTML 或 SVG 代码',
                        ),
                      ),
                    )
                  : ColoredBox(
                      color: scheme.surfaceContainer,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: _phoneWidth && !compact
                                ? _deviceWidth
                                : double.infinity,
                          ),
                          child: SizedBox.expand(
                            child: ColoredBox(
                              color: Colors.white,
                              child: KeyedSubtree(
                                key: ValueKey(
                                  'preview-surface-$_index-$_revision',
                                ),
                                child:
                                    widget.surfaceBuilder?.call(
                                      context,
                                      buildSandboxedHtmlPreview(
                                        _current.html,
                                        fitToWindow: true,
                                      ),
                                    ) ??
                                    LocalHtmlSurface(
                                      zoom: _zoom,
                                      document: buildSandboxedHtmlPreview(
                                        _current.html,
                                        fitToWindow: true,
                                      ),
                                    ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Text(
                '本地运行 · 外部资源不加载 · 修改仅保留在当前预览页',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
