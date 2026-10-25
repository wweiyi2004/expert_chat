import '../../chat/widgets/preview_zoom_control.dart';
import '../../../domain/html/html_snippet.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import '../../../domain/desktop/workspace_tools.dart';
import '../../../domain/desktop/workspace_host.dart';
import '../../../domain/html/html_preview_sandbox.dart';
import '../../chat/widgets/local_html_surface.dart';

class _FileDraft {
  const _FileDraft(this.original, this.content, this.hash);
  final String original, content, hash;
}

class FileTabController {
  WorkspaceFileTabState? _state;
  Future<bool> requestClose() async => await _state?.requestClose() ?? true;
}

/// A revision-checked editor backed by the same scoped tools as the agent.
class WorkspaceFileTab extends StatefulWidget {
  const WorkspaceFileTab({
    super.key,
    required this.path,
    required this.session,
    this.scope = 'root',
    this.onDirtyChanged,
    this.tabController,
  });
  final String path, scope;
  final Future<WorkToolSession> session;
  final ValueChanged<bool>? onDirtyChanged;
  final FileTabController? tabController;
  @override
  State<WorkspaceFileTab> createState() => WorkspaceFileTabState();
}

class WorkspaceFileTabState extends State<WorkspaceFileTab> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _editor = _SourceController();
  CancelToken? _token;
  bool _loading = true, _saving = false, _writable = false, _wrap = true;
  bool _preview = false;
  String? _error, _hash;
  static final _drafts = <String, _FileDraft>{};
  String? _draftKey;
  String _original = '';
  Uint8List? _image;
  bool get _isImage => const [
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'ico',
  ].contains(_extension);
  bool get dirty => _editor.text != _original;
  String get _extension => widget.path.split('.').last.toLowerCase();
  bool get _hasPreview =>
      const ['md', 'markdown', 'html', 'htm', 'svg'].contains(_extension);
  @override
  void initState() {
    super.initState();
    widget.tabController?._state = this;
    _preview = _hasPreview;
    _editor.addListener(_changed);
    _load();
  }

  bool _dirtyReportScheduled = false;
  void _notifyDirty() {
    if (_dirtyReportScheduled || !mounted) return;
    _dirtyReportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dirtyReportScheduled = false;
      if (mounted) widget.onDirtyChanged?.call(dirty);
    });
  }

  void _changed() {
    _notifyDirty();
    if (mounted) setState(() {});
  }

  Future<Map<String, dynamic>> _read(
    WorkToolSession session,
    CancelToken token,
  ) async => Map<String, dynamic>.from(
    jsonDecode(
          await session.call('coding_read_file', {
            'scope': widget.scope,
            'path': widget.path,
            if (_isImage) 'encoding': 'base64',
          }, token),
        )
        as Map,
  );
  Future<void> _load() async {
    _token?.cancel();
    final token = CancelToken();
    _token = token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = await widget.session;
      _draftKey = jsonEncode([session.changeTarget, widget.scope, widget.path]);
      final data = await _read(session, token);
      var writable = !_isImage;
      if (session is WorkspaceToolSession) {
        writable =
            !_isImage &&
            session.workspace.scopes
                    .where((s) => s.name == widget.scope)
                    .firstOrNull
                    ?.access ==
                WorkspaceAccess.readWrite;
      }
      if (!mounted || token.isCancelled) return;
      if (_isImage) {
        _image = base64Decode(data['content'] as String);
        setState(() {
          _loading = false;
          _writable = false;
        });
        return;
      }
      _original = data['content'] as String;
      _hash =
          data['sha256'] as String? ??
          sha256.convert(utf8.encode(_original)).toString();
      final draft = _drafts[_draftKey];
      if (draft != null) {
        final diskHash = _hash;
        _original = draft.original;
        _hash = draft.hash;
        _editor.text = draft.content;
        if (diskHash != draft.hash) _error = '已恢复未保存的编辑；磁盘版本已变化，保存前请比较并合并。';
      } else {
        _editor.text = _original;
      }
      setState(() {
        _loading = false;
        _writable = writable;
      });
      _notifyDirty();
    } catch (error) {
      if (mounted && !token.isCancelled) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  Future<bool> save() async {
    if (!dirty) return true;
    if (_saving || !_writable || _hash == null) return false;
    final token = CancelToken();
    _token = token;
    setState(() {
      _saving = true;
      _error = null;
    });
    final text = _editor.text;
    try {
      final session = await widget.session;
      final result =
          jsonDecode(
                await session.call('coding_write_file', {
                  'scope': widget.scope,
                  'path': widget.path,
                  'content': text,
                  'expected_sha256': _hash,
                }, token),
              )
              as Map;
      if (!mounted) return false;
      _original = text;
      _drafts.remove(_draftKey);
      _hash =
          result['sha256'] as String? ??
          sha256.convert(utf8.encode(text)).toString();
      _notifyDirty();
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() => _error = '$error');
      // Re-read solely to present a conflict; never retry a write automatically.
      try {
        final remote = await _read(await widget.session, token);
        if (mounted && remote['sha256'] != _hash) await _conflict(remote);
      } catch (_) {}
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _conflict(Map<String, dynamic> remote) async {
    final disk = remote['content'] as String;
    final action = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('文件已被其他操作修改'),
        content: SizedBox(
          width: 860,
          height: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('保存已停止。比较磁盘版本和当前编辑；合并后可再次保存。'),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: _diffPane('磁盘版本', disk)),
                    const VerticalDivider(),
                    Expanded(child: _diffPane('当前编辑', _editor.text)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('保留编辑，暂不保存'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, 'reload'),
            child: const Text('放弃编辑并重新读取'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, 'merge'),
            child: const Text('以磁盘版本为基准继续合并'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'reload') {
      _drafts.remove(_draftKey);
      await _load();
    }
    if (action == 'merge') {
      setState(() {
        _hash = remote['sha256'] as String;
        _original = disk;
        _preview = false;
        _error = '已更新比较基准。请合并差异后按 Ctrl+S 保存。';
      });
      _notifyDirty();
    }
  }

  Widget _diffPane(String label, String text) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label),
      const Divider(),
      Expanded(
        child: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
          ),
        ),
      ),
    ],
  );
  Future<bool> requestClose() async {
    if (!dirty) return true;
    final action = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('保存文件更改？'),
        content: Text(widget.path),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, 'discard'),
            child: const Text('放弃更改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (action == 'discard') {
      _original = _editor.text;
      _drafts.remove(_draftKey);
      return true;
    }
    return action == 'save' && await save();
  }

  @override
  void dispose() {
    if (dirty && _draftKey != null && _hash != null) {
      _drafts[_draftKey!] = _FileDraft(_original, _editor.text, _hash!);
    }
    widget.tabController?._state = null;
    _token?.cancel('文件标签已关闭');
    _editor.removeListener(_changed);
    _editor.dispose();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  Widget _source(ColorScheme scheme) => LayoutBuilder(
    builder: (context, constraints) {
      _editor.scheme = scheme;
      const style = TextStyle(
        fontFamily: 'Consolas',
        fontFamilyFallback: [
          'NotoSansSC',
          'Microsoft YaHei',
          'PingFang SC',
          'monospace',
        ],
        fontSize: 13,
        height: 1.6,
      );
      final available = math.max(80.0, constraints.maxWidth - 78);
      final painter = TextPainter(
        text: const TextSpan(text: 'M', style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final characterWidth = painter.width;
      final lineHeight = painter.height;
      final lines = _editor.text.split('\n');
      final longest = lines.fold<int>(
        0,
        (a, b) => math.max(
          a,
          b
              .replaceAll('\t', '    ')
              .runes
              .fold<int>(0, (n, r) => n + (r > 255 ? 2 : 1)),
        ),
      );
      final contentWidth = _wrap
          ? available
          : math.max(available, longest * characterWidth + 32);
      final lineNumbers = Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < lines.length; i++)
            SizedBox(
              height: _wrap
                  ? _visualLineHeight(lines[i], contentWidth, style, lineHeight)
                  : lineHeight,
              child: Text(
                '${i + 1}',
                style: style.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: .55),
                ),
              ),
            ),
        ],
      );
      final content = SizedBox(
        width: contentWidth + 78,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 52, child: lineNumbers),
              const SizedBox(width: 16),
              SizedBox(
                width: contentWidth,
                child: TextField(
                  controller: _editor,
                  readOnly: !_writable,
                  maxLines: null,
                  style: style.copyWith(color: scheme.onSurface),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      );
      final vertical = Scrollbar(
        controller: _vertical,
        thumbVisibility: true,
        child: SingleChildScrollView(controller: _vertical, child: content),
      );
      if (_wrap) return vertical;
      return Scrollbar(
        controller: _horizontal,
        thumbVisibility: true,
        notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(
          controller: _horizontal,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth + 78,
            height: constraints.maxHeight,
            child: vertical,
          ),
        ),
      );
    },
  );
  double _visualLineHeight(
    String line,
    double width,
    TextStyle style,
    double minimum,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: line.isEmpty ? ' ' : line, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    return math.max(minimum, painter.height);
  }

  double? _previewZoom;

  Widget _renderPreview() {
    if (const ['md', 'markdown'].contains(_extension)) {
      return SelectionArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: GptMarkdown(_editor.text),
        ),
      );
    }
    return LocalHtmlSurface(
      key: ValueKey(_editor.text),
      zoom: _previewZoom,
      document: buildSandboxedHtmlPreview(
        previewSnippetForCode(_extension, _editor.text)?.html ?? _editor.text,
        fitToWindow: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          save();
        },
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
          save();
        },
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: '${widget.scope} · ${widget.path}',
                      child: Text(
                        '${dirty ? '● ' : ''}${widget.path}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  if (_preview &&
                      _extension != 'md' &&
                      _extension != 'markdown')
                    PreviewZoomControl(
                      zoom: _previewZoom,
                      onChanged: (value) =>
                          setState(() => _previewZoom = value),
                    ),
                  if (!_writable)
                    Text('只读', style: Theme.of(context).textTheme.labelSmall),
                  if (_hasPreview)
                    TextButton.icon(
                      onPressed: () => setState(() => _preview = !_preview),
                      icon: Icon(
                        _preview ? Icons.code : Icons.visibility_outlined,
                        size: 17,
                      ),
                      label: Text(_preview ? '源码' : '预览'),
                    ),
                  IconButton(
                    tooltip: _wrap ? '切换为横向滚动' : '开启自动换行',
                    isSelected: _wrap,
                    icon: const Icon(Icons.wrap_text, size: 18),
                    onPressed: () => setState(() => _wrap = !_wrap),
                  ),
                  IconButton(
                    tooltip: '保存 · Ctrl+S',
                    icon: const Icon(Icons.save_outlined, size: 18),
                    onPressed: !_loading && _writable && dirty && !_saving
                        ? () {
                            save();
                          }
                        : null,
                  ),
                  IconButton(
                    tooltip: '复制文件内容',
                    icon: const Icon(Icons.copy_outlined, size: 17),
                    onPressed: _loading
                        ? null
                        : () => Clipboard.setData(
                            ClipboardData(text: _editor.text),
                          ),
                  ),
                  IconButton(
                    tooltip: '重新读取文件',
                    icon: const Icon(Icons.refresh, size: 19),
                    onPressed: _loading
                        ? null
                        : () async {
                            if (await requestClose()) await _load();
                          },
                  ),
                ],
              ),
            ),
            if (_saving) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Material(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null && _hash == null
                  ? Center(child: Text('无法打开此文件：$_error'))
                  : _image != null
                  ? InteractiveViewer(
                      minScale: .1,
                      maxScale: 8,
                      child: Center(child: Image.memory(_image!)),
                    )
                  : _preview
                  ? _renderPreview()
                  : _source(scheme),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lightweight lexical highlighting without changing editable text offsets.
class _SourceController extends TextEditingController {
  ColorScheme? scheme;
  static final _tokens = RegExp(
    r'''(//[^\n]*|\#[^\n]*|/\*[\s\S]*?\*/)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|\b(class|def|return|if|else|for|while|import|from|as|const|final|var|void|int|double|float|bool|true|false|null|None|True|False|public|private|static|async|await|try|catch|throw|new|using|namespace|include|struct|switch|case|break|function|let|export)\b|\b(\d+(?:\.\d+)?)\b''',
  );
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (value.composing.isValid && !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final colors = scheme ?? Theme.of(context).colorScheme;
    final spans = <TextSpan>[];
    var offset = 0;
    for (final match in _tokens.allMatches(text)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: text.substring(offset, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(0),
          style: TextStyle(
            color: match.group(1) != null
                ? colors.onSurfaceVariant.withValues(alpha: .65)
                : match.group(2) != null
                ? colors.tertiary
                : match.group(3) != null
                ? colors.primary
                : colors.secondary,
          ),
        ),
      );
      offset = match.end;
    }
    if (offset < text.length) spans.add(TextSpan(text: text.substring(offset)));
    return TextSpan(style: style, children: spans);
  }
}
