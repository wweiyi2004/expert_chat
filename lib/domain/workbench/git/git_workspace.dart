typedef GitAuthorization = Future<void> Function(bool write);

class GitChange {
  const GitChange(this.path, this.indexStatus, this.worktreeStatus);
  final String path;
  final String indexStatus;
  final String worktreeStatus;
  bool get untracked => indexStatus == '?' && worktreeStatus == '?';
  String get status => '$indexStatus$worktreeStatus'.trim();
}

class GitCommit {
  const GitCommit(
    this.id,
    this.parents,
    this.subject,
    this.author,
    this.date, [
    this.refs = '',
  ]);
  final String refs;
  final String id;
  final List<String> parents;
  final String subject;
  final String author;
  final String date;
}

class GitWorktree {
  const GitWorktree(this.path, this.branch, this.head, this.locked);
  final String path;
  final String branch;
  final String head;
  final bool locked;
}

class GitWorkspaceSnapshot {
  const GitWorkspaceSnapshot({
    required this.isRepository,
    this.branch = '',
    this.branches = const [],
    this.changes = const [],
    this.commits = const [],
    this.worktrees = const [],
    this.message,
  });
  final bool isRepository;
  final String branch;
  final List<String> branches;
  final List<GitChange> changes;
  final List<GitCommit> commits;
  final List<GitWorktree> worktrees;
  final String? message;
}

abstract interface class GitWorkspaceService {
  Future<GitWorkspaceSnapshot> load();
  Future<String> diff(GitChange change);
  Future<String> commitDiff(String id);
  String worktreeTarget(String branch);
  Future<void> createWorktree(String branch);
}

class GitWorkspaceException implements Exception {
  const GitWorkspaceException(this.message);
  final String message;
  @override
  String toString() => message;
}
