import 'dart:async';

import 'package:flutter/material.dart';

/// A secret edit belongs to this field's identity (e.g. provider id), including
/// when a pending save is flushed while switching to a different provider.
class DebouncedSecretField extends StatefulWidget {
  const DebouncedSecretField({
    super.key,
    required this.value,
    required this.onSaved,
    required this.decoration,
    this.obscureText = true,
  });

  final String value;
  final Future<void> Function(String) onSaved;
  final InputDecoration decoration;
  final bool obscureText;

  @override
  State<DebouncedSecretField> createState() => _DebouncedSecretFieldState();
}

class _DebouncedSecretFieldState extends State<DebouncedSecretField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.value,
  );
  final _focus = FocusNode();
  Timer? _timer;
  bool _dirty = false;
  int _pendingSaves = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _flush();
  }

  @override
  void didUpdateWidget(DebouncedSecretField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dirty && _pendingSaves == 0 && _text.text != widget.value) {
      _text.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  void _flush({bool disposing = false}) {
    _timer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    final save = widget.onSaved;
    final value = _text.text;
    _pendingSaves++;
    // Dispose can run during a build; publish provider state after that frame.
    unawaited(
      Future<void>.microtask(() async {
        try {
          await save(value);
          if (mounted && !disposing && _text.text == value) {
            setState(() => _error = null);
          }
        } catch (_) {
          if (mounted && !disposing && _text.text == value) {
            setState(() {
              _dirty = true;
              _error = '保存失败，请重新编辑后重试';
            });
          }
        } finally {
          _pendingSaves--;
        }
      }),
    );
  }

  @override
  void dispose() {
    _flush(disposing: true);
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    focusNode: _focus,
    obscureText: widget.obscureText,
    autocorrect: false,
    enableSuggestions: false,
    decoration: widget.decoration.copyWith(errorText: _error),
    onChanged: (_) {
      _dirty = true;
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 500), _flush);
    },
    onSubmitted: (_) => _flush(),
  );
}
