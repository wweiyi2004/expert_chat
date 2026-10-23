final class PtyCapabilities {
  const PtyCapabilities({
    required this.posixSignals,
    required this.foregroundProcessGroups,
    required this.pixelDimensions,
    required this.reliableProcessTreeKill,
    required this.conPty,
  });

  final bool posixSignals;
  final bool foregroundProcessGroups;
  final bool pixelDimensions;
  final bool reliableProcessTreeKill;
  final bool conPty;
}
