import 'package:flutter/material.dart';

/// The route owns its controller until the reverse transition unmounts it.
class TextValueDialog extends StatefulWidget {
  const TextValueDialog({
    super.key,
    required this.title,
    required this.initialText,
    required this.label,
    this.description = '',
    this.minLines = 1,
    this.maxLines = 8,
    this.maxLength = 24000,
  });
  final String title, initialText, label, description;
  final int minLines, maxLines, maxLength;
  @override
  State<TextValueDialog> createState() => _TextValueState();
}

class _TextValueState extends State<TextValueDialog> {
  late final _text = TextEditingController(text: widget.initialText);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.description.isNotEmpty) SelectableText(widget.description),
          if (widget.description.isNotEmpty) const SizedBox(height: 12),
          TextField(
            controller: _text,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            maxLength: widget.maxLength,
            decoration: InputDecoration(labelText: widget.label),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text),
        child: const Text('保存'),
      ),
    ],
  );
}
