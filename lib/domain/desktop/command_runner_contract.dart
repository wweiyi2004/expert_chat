/// Incremental decoded output. A chunk is not necessarily a complete line.
typedef WorkspaceCommandOutput = void Function(String text, bool isStderr);
typedef WorkspaceCommandCompletion =
    void Function(WorkspaceCommandOutcome outcome);

class WorkspaceCommandOutcome {
  const WorkspaceCommandOutcome({
    this.exitCode,
    this.cancelled = false,
    this.timedOut = false,
  });

  final int? exitCode;
  final bool cancelled;
  final bool timedOut;
}
