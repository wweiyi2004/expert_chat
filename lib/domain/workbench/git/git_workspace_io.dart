import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'git_workspace.dart';

GitWorkspaceService createGitWorkspaceService({
  required String rootPath,
  required GitAuthorization authorize,
}) => _LocalGit(rootPath, authorize);

class _LocalGit implements GitWorkspaceService {
  _LocalGit(String root, this.authorize)
    : rootPath = p.normalize(p.absolute(root));
  final String rootPath;
  final GitAuthorization authorize;

  // Every invocation uses the selected root and an argument array. Git hooks,
  // external diff drivers and textconv are never used by the workbench.
  Future<({int code, String out, String error})> _run(List<String> args) async {
    late Process process;
    try {
      process = await Process.start(
        'git',
        [
          '--no-pager',
          '--no-optional-locks',
          '-c',
          'core.quotepath=false',
          '-c',
          'core.fsmonitor=false',
          '-c',
          'core.hooksPath=${Platform.isWindows ? 'NUL' : '/dev/null'}',
          ...args,
        ],
        workingDirectory: rootPath,
        runInShell: false,
        includeParentEnvironment: false,
        environment: {
          for (final entry in Platform.environment.entries)
            if (!entry.key.toUpperCase().startsWith('GIT_'))
              entry.key: entry.value,
          'GIT_OPTIONAL_LOCKS': '0',
          'GIT_TERMINAL_PROMPT': '0',
          'GIT_LITERAL_PATHSPECS': '1',
        },
      );
    } on ProcessException catch (error) {
      throw GitWorkspaceException('无法启动 Git，请确认已安装 Git：${error.message}');
    }
    await process.stdin.close();
    Future<String> collect(Stream<List<int>> stream) async {
      final bytes = <int>[];
      var overflow = false;
      await for (final chunk in stream) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          overflow = true;
          process.kill();
        } else if (!overflow) {
          bytes.addAll(chunk);
        }
      }
      if (overflow) throw const GitWorkspaceException('Git 输出过大，请缩小查看范围。');
      return utf8.decode(bytes, allowMalformed: true);
    }

    final output = collect(process.stdout);
    final error = collect(process.stderr);
    final timer = Timer(const Duration(seconds: 45), () => process.kill());
    try {
      // Attach all consumers immediately so a stream error is never unhandled.
      final results = await Future.wait<Object>([
        process.exitCode,
        output,
        error,
      ]);
      return (
        code: results[0] as int,
        out: results[1] as String,
        error: results[2] as String,
      );
    } finally {
      timer.cancel();
    }
  }

  Future<String> _checked(List<String> args) async {
    final result = await _run(args);
    if (result.code != 0) {
      throw GitWorkspaceException(
        result.error.trim().isEmpty ? 'Git 未完成操作。' : result.error.trim(),
      );
    }
    return result.out;
  }

  Future<bool> _repository() async {
    final result = await _run(['rev-parse', '--show-toplevel']);
    if (result.code != 0) {
      if (result.error.contains('not a git repository')) return false;
      throw GitWorkspaceException(result.error.trim());
    }
    final actual = await Directory(rootPath).resolveSymbolicLinks();
    if (!p.equals(p.normalize(result.out.trim()), p.normalize(actual))) {
      throw const GitWorkspaceException('当前工作区是仓库的子目录。请将仓库根目录添加为工作区后查看 Git。');
    }
    return true;
  }

  @override
  Future<GitWorkspaceSnapshot> load() async {
    await authorize(false);
    if (!await _repository()) {
      return const GitWorkspaceSnapshot(
        isRepository: false,
        message: '这个工作区还不是 Git 仓库，仍可浏览文件。',
      );
    }
    final status = await _checked([
      'status',
      '--porcelain=v1',
      '-z',
      '--untracked-files=normal',
    ]);
    final changes = <GitChange>[];
    final records = status.split('\x00');
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      if (record.length < 4) continue;
      changes.add(GitChange(record.substring(3), record[0], record[1]));
      if (record[0] == 'R' ||
          record[0] == 'C' ||
          record[1] == 'R' ||
          record[1] == 'C')
        i++;
    }
    final branchResult = await _run([
      'symbolic-ref',
      '--quiet',
      '--short',
      'HEAD',
    ]);
    final branch = branchResult.code == 0 ? branchResult.out.trim() : '分离 HEAD';
    final branches = (await _checked([
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/heads/',
    ])).split('\n').where((s) => s.isNotEmpty).toList();
    final head = await _run(['rev-parse', '--verify', 'HEAD']);
    final commits = <GitCommit>[];
    if (head.code == 0) {
      final log = await _checked([
        'log',
        '--all',
        '--topo-order',
        '-120',
        '--date=short',
        '--format=%H%x00%P%x00%s%x00%an%x00%ad%x00%D%x00',
      ]);
      final parts = log.split('\x00');
      for (var i = 0; i + 5 < parts.length; i += 6) {
        commits.add(
          GitCommit(
            parts[i].trim(),
            parts[i + 1].split(' ').where((s) => s.isNotEmpty).toList(),
            parts[i + 2],
            parts[i + 3],
            parts[i + 4],
            parts[i + 5],
          ),
        );
      }
    }
    final worktrees = <GitWorktree>[];
    final rawWorktrees = await _checked([
      'worktree',
      'list',
      '--porcelain',
      '-z',
    ]);
    var fields = <String, String>{};
    void finish() {
      if (fields.containsKey('worktree')) {
        worktrees.add(
          GitWorktree(
            fields['worktree']!,
            (fields['branch'] ?? '分离 HEAD').replaceFirst('refs/heads/', ''),
            fields['HEAD'] ?? '',
            fields.containsKey('locked'),
          ),
        );
      }
      fields = {};
    }

    for (final part in rawWorktrees.split('\x00')) {
      if (part.isEmpty) {
        finish();
        continue;
      }
      final split = part.indexOf(' ');
      fields[split < 0 ? part : part.substring(0, split)] = split < 0
          ? ''
          : part.substring(split + 1);
    }
    finish();
    return GitWorkspaceSnapshot(
      isRepository: true,
      branch: branch,
      branches: branches,
      changes: changes,
      commits: commits,
      worktrees: worktrees,
    );
  }

  @override
  Future<String> diff(GitChange change) async {
    await authorize(false);
    if (!await _repository()) throw const GitWorkspaceException('仓库已不可用，请刷新。');
    if (change.untracked) return '尚未跟踪的文件，可切换到文件页查看内容。';
    final work = await _checked([
      'diff',
      '--no-ext-diff',
      '--no-textconv',
      '--',
      change.path,
    ]);
    final staged = await _checked([
      'diff',
      '--cached',
      '--no-ext-diff',
      '--no-textconv',
      '--',
      change.path,
    ]);
    return [
      if (staged.isNotEmpty) '已暂存\n$staged',
      if (work.isNotEmpty) '未暂存\n$work',
    ].join('\n');
  }

  @override
  Future<String> commitDiff(String id) async {
    if (!RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(id))
      throw const GitWorkspaceException('无效的提交 ID');
    await authorize(false);
    return _checked([
      'show',
      '--format=fuller',
      '--stat',
      '--patch',
      '--no-ext-diff',
      '--no-textconv',
      id,
      '--',
    ]);
  }

  @override
  String worktreeTarget(String branch) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$').hasMatch(branch)) {
      throw const GitWorkspaceException('分支名使用 1–80 位字母、数字、下划线或短横线，以字母或数字开头。');
    }
    return p.join(
      p.dirname(rootPath),
      '${p.basename(rootPath)}-worktrees',
      branch,
    );
  }

  @override
  Future<void> createWorktree(String branch) async {
    final target = worktreeTarget(branch);
    await authorize(true);
    if (!await _repository())
      throw const GitWorkspaceException('当前目录不是 Git 仓库。');
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const GitWorkspaceException('目标路径已经存在，请选择新的分支名称。');
    }
    final parent = Directory(p.dirname(target));
    if (await parent.exists()) {
      final resolved = await parent.resolveSymbolicLinks();
      final originalParent = await Directory(
        p.dirname(rootPath),
      ).resolveSymbolicLinks();
      if (!p.equals(
        resolved,
        p.join(originalParent, '${p.basename(rootPath)}-worktrees'),
      )) {
        throw const GitWorkspaceException('目标父目录是重定向路径，请使用普通目录。');
      }
    }
    await _checked(['worktree', 'add', '-b', branch, '--', target, 'HEAD']);
  }
}
