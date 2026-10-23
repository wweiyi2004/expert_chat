import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'terminal_style.dart';
import '../../../domain/desktop/workspace_tools.dart';
import '../../../domain/research/research_workspace.dart';
import '../../../domain/workbench/terminal/local_terminal.dart';
import '../../../domain/workbench/terminal/terminal_connection.dart';

class WorkspaceCommandPanel extends StatefulWidget {
  const WorkspaceCommandPanel({
    super.key,
    required this.session,
    this.active = true,
  });
  final Future<WorkToolSession> session;
  final bool active;
  @override
  State<WorkspaceCommandPanel> createState() => _WorkspaceCommandPanelState();
}

class _WorkspaceCommandPanelState extends State<WorkspaceCommandPanel> {
  final _terminal = Terminal(maxLines: 10000);
  final _controller = TerminalController();
  final _focus = FocusNode();
  TerminalConnection? _connection;
  StreamSubscription<String>? _output;
  bool _opening = true, _exited = false;
  String _label = '终端';
  String? _error;
  int _columns = 80, _rows = 24;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (text) async {
      try {
        await _connection?.write(utf8.encode(text));
      } catch (error) {
        if (mounted) setState(() => _error = '$error');
      }
    };
    _terminal.onResize = (columns, rows, width, height) {
      // Offstage/layout transitions must never resize the shell to zero.
      if (columns < 1 || rows < 1) return;
      _columns = columns;
      _rows = rows;
      try {
        _connection?.resize(columns, rows);
      } catch (error) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _error = '$error');
        });
      }
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
  }

  void _focusTerminal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant WorkspaceCommandPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _focusTerminal();
  }

  Future<void> _open() async {
    setState(() {
      _opening = true;
      _error = null;
      _exited = false;
    });
    try {
      await _output?.cancel();
      await _connection?.close();
      _connection = null;
      if (!mounted) return;
      final session = await widget.session;
      if (!mounted) return;
      final TerminalConnection connection;
      if (session is WorkspaceToolSession) {
        await session.authorizeCommand();
        if (!mounted) return;
        connection = await openLocalTerminal(
          session.workspace.root,
          _columns,
          _rows,
        );
        _label = connection is TerminalShellInfo
            ? '本机 · ${(connection as TerminalShellInfo).shellLabel}'
            : '本机终端';
      } else if (session is ResearchWorkspaceSession &&
          session.openTerminal != null) {
        session.validate();
        connection = await session.openTerminal!(_columns, _rows);
        _label = 'SSH · ${session.label}';
      } else {
        throw UnsupportedError('当前工作区不支持交互式终端。');
      }
      if (!mounted) {
        await connection.close();
        return;
      }
      _connection = connection;
      connection.resize(_columns, _rows);
      _output = connection.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            _terminal.write,
            onError: (Object error) {
              if (mounted) setState(() => _error = '$error');
            },
          );
      connection.exitCode.then(
        (code) {
          if (!mounted || !identical(_connection, connection)) return;
          _terminal.write('\r\n[终端已退出${code == null ? '' : '，退出码 $code'}]\r\n');
          setState(() => _exited = true);
        },
        onError: (Object error) {
          if (mounted && identical(_connection, connection)) {
            setState(() {
              _exited = true;
              _error = '$error';
            });
          }
        },
      );
      setState(() => _opening = false);
      _focusTerminal();
    } catch (error) {
      if (mounted)
        setState(() {
          _opening = false;
          _exited = true;
          _error = '$error';
        });
    }
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (mounted && !_exited && !_opening && text != null) {
      _terminal.paste(text);
      _focusTerminal();
    }
  }

  Future<void> _copy() async {
    final selection = _controller.selection;
    if (selection == null) return;
    await Clipboard.setData(
      ClipboardData(text: _terminal.buffer.getText(selection)),
    );
  }

  @override
  void dispose() {
    _terminal.onOutput = null;
    _terminal.onResize = null;
    unawaited(_output?.cancel());
    unawaited(_connection?.close());
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: 36,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _opening ? '正在启动终端…' : _label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_exited && !_opening)
              TextButton(onPressed: _open, child: const Text('重新打开')),
            IconButton(
              tooltip: '复制选中内容 · Ctrl+Shift+C',
              onPressed: _copy,
              icon: const Icon(Icons.copy_outlined, size: 16),
            ),
            IconButton(
              tooltip: '粘贴 · Ctrl+V',
              onPressed: _exited || _opening ? null : _paste,
              icon: const Icon(Icons.content_paste, size: 16),
            ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(
        child: ExcludeFocus(
          excluding: !widget.active,
          child: TerminalView(
            _terminal,
            controller: _controller,
            focusNode: _focus,
            autofocus: false,
            readOnly: _opening || _exited,
            theme: workspaceTerminalTheme(Theme.of(context).colorScheme),
            textStyle: const TerminalStyle(
              fontSize: 14,
              fontFamily: 'Cascadia Mono',
              fontFamilyFallback: ['Consolas', 'Courier New', 'monospace'],
            ),
            padding: const EdgeInsets.all(10),
            onSecondaryTapUp: (details, offset) async {
              final action = await showMenu<String>(
                context: context,
                position: RelativeRect.fromLTRB(
                  details.globalPosition.dx,
                  details.globalPosition.dy,
                  MediaQuery.sizeOf(context).width - details.globalPosition.dx,
                  MediaQuery.sizeOf(context).height - details.globalPosition.dy,
                ),
                items: [
                  PopupMenuItem(
                    value: 'copy',
                    enabled: _controller.selection != null,
                    child: const Text('复制'),
                  ),
                  PopupMenuItem(
                    value: 'paste',
                    enabled: !_opening && !_exited,
                    child: const Text('粘贴'),
                  ),
                ],
              );
              if (!mounted) return;
              if (action == 'copy') await _copy();
              if (action == 'paste') await _paste();
            },
          ),
        ),
      ),
      if (MediaQuery.sizeOf(context).width < 600)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final shortcut in const [
                ('Esc', '\x1b'),
                ('Tab', '\t'),
                ('↑', '\x1b[A'),
                ('↓', '\x1b[B'),
                ('Ctrl+C', '\x03'),
              ])
                TextButton(
                  onPressed: _opening || _exited
                      ? null
                      : () {
                          _terminal.onOutput?.call(shortcut.$2);
                          _focusTerminal();
                        },
                  child: Text(
                    shortcut.$1,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
    ],
  );
}
