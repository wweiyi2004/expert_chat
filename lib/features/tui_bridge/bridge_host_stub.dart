import 'package:flutter/widgets.dart';

class TuiBridgeHost extends StatelessWidget {
  const TuiBridgeHost({super.key, required this.child, this.enabled = false});
  final Widget child;
  final bool enabled;
  @override
  Widget build(BuildContext context) => child;
}
