/// Breakpoints and pane defaults for adaptive workspace chrome.
abstract final class WorkspaceBreakpoints {
  /// History as side panel (else drawer).
  static const double dualPane = 840;

  /// Optional tools / story panel on the right.
  static const double triplePane = 1200;

  /// Shell uses its unified desktop sidebar instead of the bottom bar.
  static const double shellRail = 840;
}

abstract final class WorkspacePaneDefaults {
  static const double historyWidth = 300;
  static const double toolsWidth = 340;
  static const double historyMin = 240;
  static const double historyMax = 420;
  static const double toolsMin = 280;
  static const double toolsMax = 480;
}
