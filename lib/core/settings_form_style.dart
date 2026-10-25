import 'package:flutter/material.dart';

/// Comfortable form metrics scoped to settings, leaving chat input compact.
class SettingsFormStyle extends StatelessWidget {
  const SettingsFormStyle({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          isDense: false,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 16,
          ),
          helperMaxLines: 4,
          errorMaxLines: 4,
          helperStyle: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
          errorStyle: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
            height: 1.5,
          ),
        ),
      ),
      child: child,
    );
  }
}
