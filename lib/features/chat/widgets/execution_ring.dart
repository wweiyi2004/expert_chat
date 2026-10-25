import 'package:flutter/material.dart';
import 'execution_status_indicator.dart';

/// An indeterminate execution indicator; no percentage is implied.
class ExecutionRing extends StatelessWidget {
  const ExecutionRing({super.key, this.size = 12, this.color});
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => ExecutionStatusIndicator(
    status: ExecutionVisualStatus.running,
    size: size,
    color: color,
  );
}
