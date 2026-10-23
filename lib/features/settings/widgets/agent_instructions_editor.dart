import 'package:flutter/material.dart';

class AgentInstructionsEditor extends StatefulWidget {
  const AgentInstructionsEditor({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.onSaved,
    required this.icon,
    this.defaultValue = '',
  });
  final String title, description, value, defaultValue;
  final IconData icon;
  final Future<void> Function(String) onSaved;
  @override
  State<AgentInstructionsEditor> createState() =>
      _AgentInstructionsEditorState();
}

class _AgentInstructionsEditorState extends State<AgentInstructionsEditor> {
  String _effective(String value) =>
      value.trim().isEmpty ? widget.defaultValue : value;
  late final _text = TextEditingController(text: _effective(widget.value));
  late String _saved = widget.value;
  bool _saving = false;
  String? _error;
  bool get _dirty => _text.text.trim() != _effective(_saved).trim();
  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() => _error = null);
  }

  @override
  void didUpdateWidget(covariant AgentInstructionsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      if (!_dirty) _text.text = _effective(widget.value);
      _saved = widget.value;
    }
  }

  @override
  void dispose() {
    _text.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  Future<void> _save({bool clear = false}) async {
    final text = _text.text.trim();
    final value = clear || text == widget.defaultValue.trim() ? '' : text;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSaved(value);
      if (!mounted) return;
      _saved = value;
      final shown = _effective(value);
      if (_text.text != shown) _text.text = shown;
    } catch (error) {
      if (mounted) _error = '$error';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(widget.icon, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(widget.title, style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              widget.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              readOnly: _saving,
              minLines: 5,
              maxLines: 12,
              maxLength: 24000,
              decoration: const InputDecoration(
                labelText: '系统指令（可编辑）',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
                hintText: '填写角色、工作流程、回复风格或交付要求。',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: TextStyle(color: colors.error)),
              ),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 6,
              children: [
                Text(
                  _saving
                      ? '保存中…'
                      : _dirty
                      ? '未保存'
                      : _saved.isEmpty
                      ? '使用默认'
                      : '已保存',
                  style: theme.textTheme.bodySmall,
                ),
                TextButton(
                  onPressed: !_saving && (_dirty || _saved.isNotEmpty)
                      ? () => _save(clear: true)
                      : null,
                  child: const Text('恢复默认'),
                ),
                FilledButton.icon(
                  onPressed: !_saving && _dirty && _text.text.length <= 24000
                      ? _save
                      : null,
                  icon: const Icon(Icons.save_outlined, size: 17),
                  label: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
