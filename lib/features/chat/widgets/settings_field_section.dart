import 'package:flutter/material.dart';

/// Labels and help text occupy their own lines, including with large text.
class SettingsFieldSection extends StatelessWidget {
  const SettingsFieldSection({
    super.key,
    required this.title,
    required this.child,
    this.description,
  });
  final String title;
  final String? description;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        child,
        if (description != null) ...[
          const SizedBox(height: 6),
          Text(description!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    ),
  );
}

const settingsControlDecoration = InputDecoration(
  border: OutlineInputBorder(),
  isDense: false,
  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
);
