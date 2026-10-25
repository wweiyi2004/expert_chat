import 'package:flutter/material.dart';

class PreviewZoomControl extends StatelessWidget {
  const PreviewZoomControl({
    super.key,
    required this.zoom,
    required this.onChanged,
  });
  final double? zoom;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
    tooltip: '预览缩放：${zoom == null ? '适配窗口' : '${(zoom! * 100).round()}%'}',
    initialValue: zoom ?? 0,
    onSelected: (value) => onChanged(value == 0 ? null : value),
    itemBuilder: (_) => [
      for (final value in [0.0, .25, .5, .75, 1.0, 1.25, 1.5, 2.0])
        PopupMenuItem(
          value: value,
          child: Text(value == 0 ? '适配窗口' : '${(value * 100).round()}%'),
        ),
    ],
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44, minWidth: 52),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          zoom == null ? '适配' : '${(zoom! * 100).round()}%',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    ),
  );
}
