import 'git_workspace.dart';

GitWorkspaceService createGitWorkspaceService({
  required String rootPath,
  required GitAuthorization authorize,
}) => _UnavailableGit();

class _UnavailableGit implements GitWorkspaceService {
  Never _unavailable() =>
      throw const GitWorkspaceException('Git 工作台需要本机桌面执行端。');
  @override
  Future<GitWorkspaceSnapshot> load() async => _unavailable();
  @override
  Future<String> diff(GitChange change) async => _unavailable();
  @override
  Future<String> commitDiff(String id) async => _unavailable();
  @override
  String worktreeTarget(String branch) => _unavailable();
  @override
  Future<void> createWorktree(String branch) async => _unavailable();
}
