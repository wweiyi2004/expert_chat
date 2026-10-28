part of 'backend.dart';

class _WorkbenchJob {
  _WorkbenchJob(this.id, this.scope, this.session, this.title);
  final String id, scope, session, title;
  CancelToken token = CancelToken();
  bool done = false;
  String output = '';
  Map<String, Object?>? result;
  final List<Map<String, Object?>> messages = [];
  final List<LlmRequestMessage> context = [];
}

extension TerminalWorkbench on ControllerBridgeBackend {
  Map<String, Object?> _field(
    String key,
    String label, [
    String value = '',
    bool edit = true,
    String? action,
  ]) => {
    'key': key,
    'label': label,
    'value': value,
    'editable': edit,
    'action': ?action,
  };
  Map<String, Object?> _panel(
    String title,
    List<Map<String, Object?>> fields, [
    Map<String, Object?> data = const {},
  ]) => {'workbench': true, 'title': title, 'fields': fields, 'data': data};
  Map<String, Object?> _textPanel(String title, String text) => _panel(title, [
    for (final (i, line) in text.split('\n').indexed.take(500))
      _field('line:$i', line, '', false),
  ]);
  Future<WorkspaceToolSession> _localWork(String id) async {
    TaskWindow.current?.ensureOpen();
    final binding = container.read(conversationWorkspaceBindingsProvider)[id];
    if (binding == null || _policy(id).sshProfileId.isNotEmpty) {
      throw const BridgeFailure('not_found', '请先选择本机已授权工作区');
    }
    final work = await WorkspaceToolSession.open(
      container.read(desktopWorkspaceHostProvider),
      binding,
      CancelToken(),
    );
    if (TaskWindow.current?.closed == true) {
      await work.close();
      TaskWindow.current!.ensureOpen();
    }
    return work;
  }

  String _filePath(String path) {
    if (Platform.isWindows) {
      if (path.toLowerCase().startsWith(r'\\?\unc\')) {
        path = r'\\' + path.substring(8);
      } else if (path.startsWith(r'\\?\')) {
        path = path.substring(4);
      }
    }
    return p.normalize(path);
  }

  String _relative(String root, String path) {
    root = _filePath(root);
    path = _filePath(path);
    final target = p.normalize(p.isAbsolute(path) ? path : p.join(root, path));
    if (!p.equals(target, root) && !p.isWithin(root, target)) {
      throw const BridgeFailure('forbidden', '文件须位于当前工作区内');
    }
    return p.relative(target, from: root);
  }

  Future<Map<String, dynamic>> _fileRead(
    WorkspaceToolSession work,
    String path,
  ) async => Map<String, dynamic>.from(
    jsonDecode(
          await work.call('coding_read_file', {
            'scope': 'root',
            'path': _relative(work.workspace.root, path),
          }, CancelToken()),
        )
        as Map,
  );
  Map<String, Object?> _jobView(_WorkbenchJob job) {
    if (job.result != null) return job.result!;
    return {
      ..._panel(
        job.title,
        [
          _field('__cancel', '停止此操作', '', false, 'wb.cancel'),
          _field('__copy', '复制输出', '', false, 'client.copy'),
          _field('__editor', '返回编辑器', '', false, 'client.editor'),
          ...(_textPanel(
                '',
                '${job.done ? '已结束' : '执行中'}\n${job.output}',
              )['fields']
              as List<Map<String, Object?>>),
        ],
        {'job_id': job.id, 'output': job.output},
      ),
      'job_id': job.id,
      'done': job.done,
    };
  }

  Map<String, Object?> _startJob(
    String scope,
    String id,
    String title,
    Future<Map<String, Object?>?> Function(_WorkbenchJob) run,
  ) {
    if (_wbJobs.values.where((j) => !j.done).length >= 8) {
      throw const BridgeFailure('busy', '后台操作已达上限');
    }
    if (_wbJobs.length > 64) _wbJobs.removeWhere((_, j) => j.done);
    final job = _WorkbenchJob(const Uuid().v4(), scope, id, title);
    final detachWindow = TaskWindow.current?.attach(job.token);
    _wbJobs[job.id] = job;
    unawaited(
      Future<void>(() async {
        try {
          if (job.token.isCancelled) return;
          job.result = await run(job);
        } catch (e) {
          job.output += '\n${job.token.isCancelled ? '已停止' : e.toString()}';
        } finally {
          detachWindow?.call();
          job.done = true;
        }
      }),
    );
    return _jobView(job);
  }

  Future<Map<String, Object?>> _workbench(
    String method,
    Map<String, dynamic> a,
  ) async {
    final id = requiredString(a, 'session_id');
    final scope = requiredString(a, '_bridge_client_scope');
    if (_releasedScopes.contains(scope)) {
      throw const BridgeFailure('disconnected', '终端已关闭');
    }
    final op = requiredString(
      a,
      method == 'terminal.query' ? 'topic' : 'action',
    );
    if (method == 'terminal.query' &&
        !terminalWorkbenchQueryTopics.contains(op)) {
      throw const BridgeFailure(
        'invalid_method',
        '该操作会改变状态，请通过 terminal.action 发起。',
      );
    }
    if (op == 'wb.jobs') {
      return _panel('后台操作', [
        for (final j in _wbJobs.values.where(
          (j) => j.scope == scope && j.session == id,
        ))
          _field(
            'job:${j.id}',
            '${j.done ? '已结束' : '执行中'} ${j.title}',
            '',
            false,
            'wb.job',
          ),
      ]);
    }
    if (op == 'wb.job' || op == 'wb.cancel') {
      final j = _wbJobs[requiredString(a, 'job_id')];
      if (j == null || j.scope != scope || j.session != id) {
        throw const BridgeFailure('not_found', '操作不属于此窗口');
      }
      if (op == 'wb.cancel') {
        j.token.cancel('用户停止');
      }
      return _jobView(j);
    }
    _session(id);
    if (op == 'wb.sessions') {
      return _panel('选择并排会话', [
        for (final c in state.conversations.where(
          (c) => c.workMode && c.id != id,
        ))
          _field('session:${c.id}', c.title, '', false, 'wb.session'),
      ]);
    }
    if (op == 'wb.session' || op == 'wb.session.send') {
      final target = a['target_session'] as String? ?? id;
      _session(target);
      if (op.endsWith('send')) {
        if (controller.isConversationRunning(target)) {
          await controller.addWorkRequirement(
            target,
            requiredString(a, 'text'),
          );
        } else {
          unawaited(
            controller.sendToSession(target, requiredString(a, 'text')),
          );
        }
      }
      return {
        ...await snapshot(target),
        'side': true,
        'kind': 'session',
        'session_id': target,
        'target_session': target,
        'title': '会话 · ${_session(target).title}',
        'status': _status(_session(target)),
        'notice': 'F6 在主会话与此会话之间切换',
      };
    }
    if (op.startsWith('wb.side')) {
      return _sideCommand(op, id, scope, a);
    }
    if (op.startsWith('wb.agent')) {
      return _agentPanel(op, id, a);
    }
    if (op.startsWith('wb.files') || op.startsWith('wb.file.')) {
      return _filesPanel(op, id, scope, a);
    }
    if (op.startsWith('wb.git')) {
      return _gitPanel(op, id, scope, a);
    }
    if (op.startsWith('wb.automation')) {
      return _automationPanel(op, id, scope, a);
    }
    if (op.startsWith('wb.backup')) {
      if (op == 'wb.backup') {
        return _panel('备份与恢复', [
          _field('path', '备份文件绝对路径'),
          _field('__preview', '查看恢复预览', '', false, 'wb.backup.preview'),
          _field('__export', '导出完整备份', '', false, 'wb.backup.export'),
        ]);
      }
      return _startJob(
        scope,
        id,
        '备份与恢复',
        (job) => terminalBackup({...a, 'operation': op.substring(3)}),
      );
    }
    if (op == 'wb.preview') {
      final raw = requiredString(a, 'path');
      String target = raw;
      if (!p.isAbsolute(raw)) {
        final w = await _localWork(id);
        try {
          target = p.join(w.workspace.root, _relative(w.workspace.root, raw));
        } finally {
          await w.close();
        }
      }
      final ext = p.extension(target).toLowerCase();
      if ({
        '.txt',
        '.md',
        '.json',
        '.csv',
        '.rs',
        '.dart',
        '.py',
        '.c',
        '.h',
        '.cpp',
        '.js',
        '.ts',
        '.yaml',
        '.toml',
        '.log',
      }.contains(ext)) {
        final w = await _localWork(id);
        try {
          final data = await _fileRead(w, target);
          return _textPanel(
            '预览 · ${p.basename(target)}',
            data['content'] as String? ?? '',
          );
        } finally {
          await w.close();
        }
      }
      if (!await File(target).exists()) {
        throw const BridgeFailure('not_found', '文件不存在');
      }
      return _mediaPanel('wb.media.preview', id, scope, {'path': target});
    }
    if (op.startsWith('wb.voice') || op.startsWith('wb.media')) {
      return _mediaPanel(op, id, scope, a);
    }
    if (op.startsWith('wb.update')) {
      return _updatePanel(op, id, scope, a);
    }
    throw const BridgeFailure('unsupported', '未知工作台操作');
  }

  Future<Map<String, Object?>> _filesPanel(
    String op,
    String id,
    String scope,
    Map<String, dynamic> a,
  ) async {
    final w = await _localWork(id);
    try {
      final root = _filePath(w.workspace.root);
      var requested = (a['path'] as String? ?? '').trim();
      if (requested.isEmpty) requested = root;
      if (op == 'wb.file.new' && a.containsKey('filename')) {
        final name = requiredString(a, 'filename').trim();
        requested = p.join(requested, name);
      }
      final rel = _relative(root, requested);
      final path = p.normalize(p.join(root, rel));
      if (op == 'wb.file.open' || op == 'wb.file.new') {
        if (await Directory(path).exists()) {
          throw const BridgeFailure('invalid_params', '请选择文件，或填写新文件名');
        }
        if (op == 'wb.file.new' && await File(path).exists()) {
          throw const BridgeFailure('conflict', '文件已存在，请打开该文件或使用其他名称');
        }
        final data = op.endsWith('new')
            ? <String, dynamic>{'content': '', 'sha256': 'new'}
            : await _fileRead(w, path);
        return {
          'editor_file': true,
          'path': path,
          'absolute_path': path,
          'content': data['content'],
          'sha256': data['sha256'],
          'session_id': id,
        };
      }
      if (op == 'wb.file.save') {
        final data =
            jsonDecode(
                  await w.call('coding_write_file', {
                    'scope': 'root',
                    'path': rel,
                    'content': requiredStringAllowEmpty(a, 'content'),
                    'expected_sha256': requiredString(a, 'sha256'),
                  }, CancelToken()),
                )
                as Map;
        return {
          'file_saved': true,
          'path': path,
          'sha256': data['sha256'],
          'session_id': id,
        };
      }
      if (op == 'wb.file.run') {
        await w.authorizeCommand();
        final current = await _fileRead(w, path);
        if (current['sha256'] != a['sha256']) {
          throw const BridgeFailure('conflict', '文件已改变，请保存或重新打开后运行');
        }
        String q(String v) => "'${v.replaceAll("'", "''")}'";
        final src = q(p.join(root, rel)),
            ext = p.extension(rel).toLowerCase(),
            dir = p.join(root, '.expert-run', const Uuid().v4());
        final binary = q(p.join(dir, 'program.exe'));
        final command = switch (ext) {
          '.py' => 'python $src',
          '.js' => 'node $src',
          '.dart' => 'dart $src',
          '.ps1' => '& $src',
          '.c' || '.cpp' || '.cc' =>
            "New-Item -ItemType Directory -Force -Path ${q(dir)} | Out-Null; & ${ext == '.c' ? 'gcc' : 'g++'} $src -o $binary; if (\$LASTEXITCODE -eq 0) { & $binary } else { exit \$LASTEXITCODE }",
          _ => throw const BridgeFailure(
            'unsupported',
            '可运行 Python / JavaScript / Dart / PowerShell / C / C++',
          ),
        };
        return _startJob(scope, id, '运行 $rel', (job) async {
          final live = await _localWork(id);
          try {
            final result = await live.call(
              'work_run_command',
              {
                'command':
                    "\$ErrorActionPreference='Stop'; $command; if (\$null -ne \$LASTEXITCODE) { exit \$LASTEXITCODE }",
                'timeout_seconds': 600,
              },
              job.token,
              onOutput: (v, isError) {
                job.output += v;
                if (job.output.length > 200000) {
                  job.output = job.output.substring(job.output.length - 200000);
                }
              },
            );
            job.output += '\n$result';
          } finally {
            await live.close();
          }
          return null;
        });
      }
      final raw = jsonDecode(
        await w.call('coding_list_directory', {
          'scope': 'root',
          'path': rel,
        }, CancelToken()),
      );
      final entries = raw is List
          ? raw
          : (raw as Map)['entries'] as List? ?? [];
      return _panel(
        '文件 · $path',
        [
          _field('path', '目录 / 文件路径', path),
          _field('filename', '新文件名'),
          _field('__go', '打开目录', '', false, 'wb.files'),
          _field('__new', '在当前目录新建文件', '', false, 'wb.file.new'),
          _field('__open', '打开上方文件路径', '', false, 'wb.file.open'),
          _field('__preview', '预览上方路径', '', false, 'wb.preview'),
          if (rel != '.')
            _field('parent', '.. 上一级', '', false, 'wb.files.parent'),
          for (final (i, v) in entries.indexed.take(100))
            _field(
              'entry:$i',
              '${v['kind'] == 'directory' || v['directory'] == true ? '▸' : '·'} ${v['name']}',
              '',
              false,
              'wb.files.entry',
            ),
        ],
        {'path': path, 'root': root, 'entries': entries},
      );
    } finally {
      await w.close();
    }
  }

  String requiredStringAllowEmpty(Map<String, dynamic> a, String key) {
    if (a[key] is! String) throw BridgeFailure('invalid_params', '缺少 $key');
    return a[key] as String;
  }

  Future<Map<String, Object?>> _gitPanel(
    String op,
    String id,
    String scope,
    Map<String, dynamic> a,
  ) async {
    final w = await _localWork(id);
    try {
      await w.authorizeCommand();
      Future<String> git(List<String> args, {String? input}) async {
        final proc = await Process.start(
          'git',
          [
            '--no-pager',
            '-c',
            'core.hooksPath=${Platform.isWindows ? 'NUL' : '/dev/null'}',
            ...args,
          ],
          workingDirectory: w.workspace.root,
          runInShell: false,
        );
        if (input != null) {
          proc.stdin.write(input);
        }
        await proc.stdin.close();
        final out = proc.stdout.transform(utf8.decoder).join(),
            err = proc.stderr.transform(utf8.decoder).join();
        final code = await proc.exitCode.timeout(
          const Duration(seconds: 45),
          onTimeout: () {
            proc.kill();
            throw TimeoutException('Git 超时');
          },
        );
        final text = '${await out}${await err}';
        if (code != 0) {
          throw BridgeFailure('git_failed', text);
        }
        return text;
      }

      final path = a['path'] as String? ?? '.';
      final branch = a['branch'] as String? ?? '';
      if (branch.startsWith('-')) {
        throw const BridgeFailure('invalid_params', '分支名无效');
      }
      switch (op) {
        case 'wb.git.stage':
          await git(['add', '--', _relative(w.workspace.root, path)]);
        case 'wb.git.unstage':
          await git([
            'restore',
            '--staged',
            '--',
            _relative(w.workspace.root, path),
          ]);
        case 'wb.git.commit':
          await git(['commit', '-m', requiredString(a, 'message')]);
        case 'wb.git.switch':
          await git(['switch', requiredString(a, 'branch')]);
        case 'wb.git.create':
          await git(['switch', '-c', requiredString(a, 'branch')]);
        case 'wb.git.merge':
          await git(['merge', '--no-edit', requiredString(a, 'branch')]);
        case 'wb.git.abort':
          await git(['merge', '--abort']);
        case 'wb.git.patch':
          await git([
            'apply',
            '--cached',
            '--check',
            '-',
          ], input: requiredString(a, 'patch'));
          await git([
            'apply',
            '--cached',
            '-',
          ], input: requiredString(a, 'patch'));
        case 'wb.git.unpatch':
          await git([
            'apply',
            '--cached',
            '--reverse',
            '--check',
            '-',
          ], input: requiredString(a, 'patch'));
          await git([
            'apply',
            '--cached',
            '--reverse',
            '-',
          ], input: requiredString(a, 'patch'));
        case 'wb.git.diff':
          return _textPanel(
            'Git 差异',
            await git([
              'diff',
              '--no-ext-diff',
              '--',
              _relative(w.workspace.root, path),
            ]),
          );
      }
      final status = await git(['status', '--short', '--branch']),
          branches = await git(['branch', '--list']);
      return _panel('Git 工作区', [
        _field('path', '文件路径（. 表示全部）', '.'),
        _field('message', '提交说明'),
        _field('branch', '分支名称'),
        for (final v in [
          ['stage', '暂存'],
          ['unstage', '取消暂存'],
          ['diff', '查看差异'],
          ['commit', '提交暂存内容'],
          ['switch', '切换分支'],
          ['create', '创建分支'],
          ['merge', '合并分支'],
          ['abort', '取消合并'],
        ])
          _field('__${v[0]}', v[1], '', false, 'wb.git.${v[0]}'),
        _field('patch', '可选：粘贴单个 diff hunk'),
        _field('__patch', '暂存上述 hunk', '', false, 'wb.git.patch'),
        _field('__unpatch', '取消暂存上述 hunk', '', false, 'wb.git.unpatch'),
        ...(_textPanel('', '$status\n$branches')['fields']
            as List<Map<String, Object?>>),
      ]);
    } finally {
      await w.close();
    }
  }

  List<LlmRequestMessage> _sideContext(String id) {
    final selection =
            container.read(contextSelectionsProvider)[id] ??
            const ContextSelection(),
        path = _session(id).activePath;
    final filtered = selection.filter(path);
    return [
      for (final m in filtered.where(
        (m) => m.role == MessageRole.user || m.role == MessageRole.assistant,
      ))
        LlmRequestMessage(
          role: m.role,
          content: [
            m.content,
            for (final a in m.attachments)
              if (a.isFileReference)
                '文件地址：${a.referencePath}'
              else if (a.text.isNotEmpty)
                a.text,
          ].join('\n'),
        ),
      if (selection.toolReferences(path).isNotEmpty)
        LlmRequestMessage(
          role: MessageRole.user,
          content: selection.toolReferences(path),
        ),
    ];
  }

  Future<Map<String, Object?>> _sideCommand(
    String op,
    String id,
    String scope,
    Map<String, dynamic> a,
  ) async {
    _WorkbenchJob? job = a['job_id'] is String ? _wbJobs[a['job_id']] : null;
    if (job != null && (job.scope != scope || job.session != id)) {
      throw const BridgeFailure('forbidden', '旁问不属于此会话');
    }
    if (op == 'wb.side.open' && job == null) {
      job = _WorkbenchJob(const Uuid().v4(), scope, id, '旁问');
      job.done = true;
      _wbJobs[job.id] = job;
      job.context.addAll(_sideContext(id));
    }
    if (job == null) {
      throw const BridgeFailure('not_found', '请先打开旁问');
    }
    if (op == 'wb.side.cancel') {
      job.token.cancel('旁问已停止');
    }
    if (op == 'wb.side.promote') {
      final text = requiredString(a, 'text');
      if (controller.isConversationRunning(id)) {
        await controller.addWorkRequirement(id, text);
      } else {
        unawaited(controller.sendToSession(id, text));
      }
    }
    if (op == 'wb.side.refresh') {
      if (!job.done) {
        throw const BridgeFailure('busy', '请等待旁问完成');
      }
      job.context
        ..clear()
        ..addAll(_sideContext(id));
    }
    if ((op == 'wb.side.open' || op == 'wb.side.send') &&
        (a['text'] as String? ?? '').trim().isNotEmpty) {
      if (!job.done) {
        throw const BridgeFailure('busy', '旁问正在回答，草稿保留');
      }
      final current = job, prompt = requiredString(a, 'text');
      current.done = false;
      current.output = '';
      current.token = CancelToken();
      current.messages.add({
        'id': const Uuid().v4(),
        'role': 'user',
        'text': prompt,
      });
      final answer = <String, Object?>{
        'id': const Uuid().v4(),
        'role': 'assistant',
        'text': '',
      };
      current.messages.add(answer);
      unawaited(
        Future<void>(() async {
          final requestId = 'side:${current.id}:${const Uuid().v4()}';
          try {
            final config = await controller.resolveSideConfig(id);
            for (final match in RegExp(
              r'@(?:"([^"]+)"|(\S+))',
            ).allMatches(prompt)) {
              final w = await _localWork(id);
              try {
                final file = await _fileRead(
                  w,
                  match.group(1) ?? match.group(2)!,
                );
                current.context.add(
                  LlmRequestMessage(
                    role: MessageRole.user,
                    content: '用户引用文件 ${match.group(0)}：\n${file['content']}',
                  ),
                );
              } finally {
                await w.close();
              }
            }
            final requests = [
              if (container
                  .read(settingsControllerProvider)
                  .requireValue
                  .systemPrompt
                  .trim()
                  .isNotEmpty)
                LlmRequestMessage(
                  role: MessageRole.system,
                  content: container
                      .read(settingsControllerProvider)
                      .requireValue
                      .systemPrompt,
                ),
              const LlmRequestMessage(
                role: MessageRole.system,
                content: '回答当前旁问。主任务继续执行。只解释公开上下文，不执行工具或声称修改文件。',
              ),
              ...current.context,
              for (final m in current.messages.where((m) => m != answer))
                LlmRequestMessage(
                  role: m['role'] == 'user'
                      ? MessageRole.user
                      : MessageRole.assistant,
                  content: m['text'] as String,
                ),
            ];
            final bounded = container
                .read(contextWindowManagerProvider)
                .manage(
                  requests,
                  effectiveContextPrefs(
                    container.read(settingsControllerProvider).requireValue,
                    config,
                  ),
                );
            container
                .read(workSessionInsightsProvider.notifier)
                .auxiliaryRequest(id, requestId, config);
            await for (final chunk
                in container
                    .read(llmProvider)
                    .streamChat(
                      config: config,
                      messages: bounded.messages,
                      thinking: false,
                      cancelToken: current.token,
                    )) {
              answer['text'] = '${answer['text']}${chunk.contentDelta ?? ''}';
              if ((answer['text'] as String).length > 200000) {
                throw const BridgeFailure('too_large', '旁问输出已达上限');
              }
              if (chunk.usage != null) {
                container
                    .read(workSessionInsightsProvider.notifier)
                    .usage(id, requestId, chunk.usage!);
              }
            }
            if (a['creative'] == true &&
                (answer['text'] as String).isNotEmpty) {
              await container
                  .read(libraryRepositoryProvider)
                  .importBytes(
                    name: '创作-${DateTime.now().millisecondsSinceEpoch}.txt',
                    mimeType: 'text/plain',
                    bytes: Uint8List.fromList(
                      utf8.encode(answer['text'] as String),
                    ),
                  );
            }
          } catch (e) {
            current.output = current.token.isCancelled ? '旁问已停止' : '旁问失败：$e';
          } finally {
            current.done = true;
          }
        }),
      );
    }
    return {
      'side': true,
      'kind': 'side',
      'job_id': job.id,
      'session_id': id,
      'title': '旁问 · 主任务继续',
      'messages': job.messages,
      'steps': [],
      'status': job.done ? 'idle' : 'running',
      'notice': job.output,
    };
  }

  Future<Map<String, Object?>> _agentPanel(
    String op,
    String id,
    Map<String, dynamic> a,
  ) async {
    final runtime = container.read(workAgentsProvider),
        agent = runtime.record(requiredString(a, 'agent_id'));
    if (agent == null || agent.conversationId != id) {
      throw const BridgeFailure('not_found', '子代理不存在');
    }
    if (op == 'wb.agent.send') {
      runtime.followup(agent.id, requiredString(a, 'text'));
    }
    if (op == 'wb.agent.cancel') {
      runtime.cancel(agent.id);
    }
    final messages = <Map<String, Object?>>[
      {'id': 'task', 'role': 'user', 'text': agent.task},
      for (final (i, m) in agent.context.indexed.where(
        (e) =>
            e.$2.role == MessageRole.user || e.$2.role == MessageRole.assistant,
      ))
        {'id': 'context:$i', 'role': m.role.name, 'text': m.content},
      if (agent.output.isNotEmpty &&
          agent.context.lastOrNull?.content != agent.output)
        {'id': 'live', 'role': 'assistant', 'text': agent.output},
    ];
    final calls = {
      for (final m in agent.context)
        for (final c in m.toolCalls) c.id: c,
    };
    final steps = <Map<String, Object?>>[
      for (final (i, m) in agent.context.indexed.where(
        (e) => e.$2.role == MessageRole.tool,
      ))
        {
          'id': m.toolCallId,
          'message_id':
              'context:${agent.context.asMap().entries.where((entry) => entry.key < i && entry.value.role == MessageRole.assistant).lastOrNull?.key ?? i}',
          'verb': calls[m.toolCallId]?.name ?? '工具',
          'object': calls[m.toolCallId]?.argumentsJson ?? '',
          'status':
              m.content.contains('"ok":false') || m.content.startsWith('工具执行失败')
              ? 'failed'
              : 'done',
          'tail': m.content.split('\n').take(3).toList(),
        },
    ];
    return {
      'side': true,
      'kind': 'agent',
      'agent_id': agent.id,
      'session_id': id,
      'title': '${agent.role?.name ?? '子代理'} · ${agent.model}',
      'messages': messages,
      'steps': steps,
      'status': agent.status == WorkAgentStatus.running
          ? 'running'
          : agent.status.name,
      'notice':
          '${agent.activity}${agent.mailbox.isEmpty ? '' : ' · ${agent.mailbox.length} 条补充待处理'}',
      'logs': agent.logs,
      'pending': agent.mailbox.toList(),
    };
  }

  Future<Map<String, Object?>> _automationPanel(
    String op,
    String id,
    String scope,
    Map<String, dynamic> a,
  ) async {
    if (op.startsWith('wb.automation.remote')) {
      return _remoteAutomation(op, id, scope, a);
    }
    final prefs = container.read(sharedPrefsProvider),
        rows =
            jsonDecode(
                  container
                          .read(sharedPrefsProvider)
                          .getString('tuiSchedules.v1') ??
                      '[]',
                )
                as List;
    final values = rows
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    if (op == 'wb.automation.save') {
      final seconds = int.tryParse(a['seconds'] as String? ?? '') ?? 0;
      if (seconds < 30) {
        throw const BridgeFailure('invalid_params', '间隔至少 30 秒');
      }
      final key = a['schedule_id'] as String? ?? const Uuid().v4();
      final w = await _localWork(id);
      late final String workspaceId, cwd;
      try {
        workspaceId = w.workspace.id;
        cwd = w.workspace.root;
      } finally {
        await w.close();
      }
      values.removeWhere((v) => v['id'] == key);
      _wbTimers.remove(key)?.cancel();
      values.add({
        'id': key,
        'session': id,
        if (TaskWindow.current case final window?) 'owner_scope': window.id,
        'workspace_id': workspaceId,
        'cwd': cwd,
        'command': requiredString(a, 'command'),
        'seconds': seconds,
        'enabled': true,
      });
      await prefs.setString('tuiSchedules.v1', jsonEncode(values));
      _armSchedule(values.last);
    }
    if (op == 'wb.automation.status') {
      final value = values.firstWhere((v) => v['id'] == a['schedule_id']);
      final job = _shellJobs[value['job_id']];
      return _textPanel(
        '运行记录',
        job == null
            ? '${value['last_run'] ?? '尚未运行'}\n${value['last_error'] ?? ''}'
            : '${job.done ? '已结束' : '运行中'} · 退出码 ${job.exitCode ?? '未报告'}\n${job.output.read(0, -1)['text']}',
      );
    }
    if (op == 'wb.automation.run') {
      final key = requiredString(a, 'schedule_id');
      await _runSchedule(key, manual: true);
      final current =
          jsonDecode(prefs.getString('tuiSchedules.v1') ?? '[]') as List;
      values
        ..clear()
        ..addAll(current.map((v) => Map<String, dynamic>.from(v as Map)));
    }
    if (op == 'wb.automation.toggle' || op == 'wb.automation.remove') {
      final key = requiredString(a, 'schedule_id'),
          value = values.firstWhere((v) => v['id'] == key);
      if (op.endsWith('toggle') &&
          value['enabled'] != true &&
          (value['workspace_id'] is! String || value['cwd'] is! String)) {
        throw const BridgeFailure('workspace_required', '旧任务未绑定工作目录，请重新保存后启用');
      }
      _wbTimers.remove(key)?.cancel();
      if (op.endsWith('remove')) {
        values.remove(value);
      } else {
        value['enabled'] = value['enabled'] != true;
        if (value['enabled'] == true) {
          _armSchedule(value);
        }
      }
      await prefs.setString('tuiSchedules.v1', jsonEncode(values));
    }
    return _panel(
      '自动化 · 定时命令',
      [
        _field('__remote', '管理远程自动化', '', false, 'wb.automation.remote'),
        _field('command', '命令'),
        _field('seconds', '间隔秒数', '300'),
        _field('__save', '创建 / 保存', '', false, 'wb.automation.save'),
        for (final (i, v) in values.indexed) ...[
          _field(
            'toggle:$i',
            '${v['enabled'] == true ? '开启' : '停用'} · ${v['seconds']}s · ${v['command']}',
            '',
            false,
            'wb.automation.toggle',
          ),
          _field('remove:$i', '删除上述任务', '', false, 'wb.automation.remove'),
          _field('run:$i', '立即执行', '', false, 'wb.automation.run'),
          _field('edit:$i', '编辑任务', '', false, 'client.schedule.edit'),
          _field('log:$i', '运行记录', '', false, 'wb.automation.status'),
          _field('cwd:$i', '工作目录：${v['cwd'] ?? '未绑定，请重新保存'}', '', false),
          _field(
            'status:$i',
            '最近执行：${v['last_run'] ?? '无'} ${v['last_error'] ?? ''}',
            '',
            false,
          ),
        ],
      ],
      {'schedules': values},
    );
  }

  Future<void> _runSchedule(String key, {bool manual = false}) async {
    if (TaskWindow.current?.closed == true) return;
    final prefs = container.read(sharedPrefsProvider);
    final saved =
        jsonDecode(prefs.getString('tuiSchedules.v1') ?? '[]') as List;
    final v = saved.where((v) => v['id'] == key).firstOrNull;
    if (v == null || (!manual && v['enabled'] != true)) return;
    final id = v['session'] as String;
    final outcome = <String, dynamic>{};
    try {
      if (_shellJobs.values.any((j) => j.session == id && !j.done)) {
        return;
      }
      if (v['workspace_id'] is! String || v['cwd'] is! String) {
        throw const BridgeFailure('workspace_required', '旧任务未绑定工作目录，请重新保存后启用');
      }
      if (container.read(conversationWorkspaceBindingsProvider)[id] !=
              v['workspace_id'] ||
          _policy(id).sshProfileId.isNotEmpty) {
        throw const BridgeFailure(
          'workspace_changed',
          '定时任务的工作区已变化，请返回原工作区或重新保存任务后执行',
        );
      }
      final receipt = await _shellCommand('terminal.action', {
        'action': 'shell.start',
        'session_id': id,
        '_bridge_client_scope': 'schedule:$key',
        'explicit': true,
        'workspace_id': v['workspace_id'],
        'cwd': v['cwd'],
        'command': v['command'],
      });
      outcome['job_id'] = receipt['job_id'];
      outcome['last_error'] = '';
    } catch (e) {
      outcome['last_error'] = e is BridgeFailure ? e.message : e.toString();
    }
    outcome['last_run'] = DateTime.now().toIso8601String();
    final rows =
        jsonDecode(
              container
                      .read(sharedPrefsProvider)
                      .getString('tuiSchedules.v1') ??
                  '[]',
            )
            as List;
    await prefs.setString(
      'tuiSchedules.v1',
      jsonEncode([
        for (final row in rows)
          if (row['id'] == key)
            {...Map<String, dynamic>.from(row as Map), ...outcome}
          else
            row,
      ]),
    );
  }

  void _armSchedule(Map<String, dynamic> v) {
    final key = v['id'] as String;
    if (_wbTimers.containsKey(key) ||
        v['workspace_id'] is! String ||
        v['cwd'] is! String) {
      return;
    }
    _wbTimers[key] = Timer.periodic(
      Duration(seconds: v['seconds'] as int),
      (_) => unawaited(_runSchedule(key)),
    );
  }

  Future<Map<String, Object?>> _remoteAutomation(
    String op,
    String id,
    String scope,
    Map<String, dynamic> a,
  ) async {
    if (op == 'wb.automation.remote') {
      return _panel('远程自动化连接', [
        _field('url', '远程 Host HTTPS 地址'),
        {..._field('token', '访问令牌'), 'secret': true},
        _field('__connect', '连接', '', false, 'wb.automation.remote.connect'),
      ]);
    }
    var handle = a['handle'] as String? ?? '';
    if (op.endsWith('connect')) {
      final url = requiredString(a, 'url'),
          uri = Uri.parse(requiredString(a, 'url'));
      if (uri.scheme != 'https' &&
          !(uri.scheme == 'http' &&
              ['localhost', '127.0.0.1', '::1'].contains(uri.host))) {
        throw const BridgeFailure('invalid_params', '远程地址需要 HTTPS，或本机回环地址');
      }
      handle = const Uuid().v4();
      _profileSecrets.add(requiredString(a, 'token'));
      _wbRemotes[handle] = {
        'scope': scope,
        'url': url.replaceFirst(RegExp(r'/+$'), ''),
        'token': requiredString(a, 'token'),
      };
    }
    final remote = _wbRemotes[handle];
    if (remote == null || remote['scope'] != scope) {
      throw const BridgeFailure('not_found', '远程连接已过期');
    }
    Future<dynamic> request(String path, [Map<String, Object?>? body]) async =>
        (await Dio().request(
          '${remote['url']}/v1/$path',
          data: body,
          options: Options(
            method: body == null ? 'GET' : 'POST',
            followRedirects: false,
            headers: {'Authorization': 'Bearer ${remote['token']}'},
          ),
        )).data;
    if (op.endsWith('save')) {
      await request('automation', {
        'item': {
          'id': requiredString(a, 'remote_id'),
          'trigger': a['trigger'] ?? 'schedule',
          'goal': requiredString(a, 'goal'),
          'path': a['path'] ?? '',
          'intervalSeconds': int.tryParse('${a['seconds']}') ?? 300,
          'autoStartModel': false,
          'policy': 'request',
          'roundLimit': 20,
          'paused': false,
        },
      });
    }
    if (op.endsWith('toggle')) {
      final item = Map<String, Object?>.from(a['item'] as Map);
      item['paused'] = item['paused'] != true;
      await request('automation', {'item': item});
    }
    if (op.endsWith('remove')) {
      await request('automation', {'delete': a['remote_id']});
    }
    if (op.endsWith('run')) {
      await request(
        'webhooks/${Uri.encodeComponent(requiredString(a, 'remote_id'))}',
        {'eventId': const Uuid().v4()},
      );
    }
    final data = Map<String, dynamic>.from(await request('automation') as Map),
        values =
            (Map<String, dynamic>.from(
                  await request('automation') as Map,
                )['automations']
                as List? ??
            []);
    return _panel(
      '远程自动化',
      [
        _field('remote_id', '任务 ID'),
        _field('goal', '任务要求'),
        _field(
          'trigger',
          '触发 schedule / file / repository / webhook',
          'schedule',
        ),
        _field('seconds', '间隔秒数', '300'),
        _field('path', '文件相对路径'),
        _field('__save', '创建 / 保存任务', '', false, 'wb.automation.remote.save'),
        for (final (i, v) in values.indexed) ...[
          _field(
            'remote_toggle:$i',
            '${v['paused'] == true ? '暂停' : '启用'} · ${v['id']}',
            '',
            false,
            'wb.automation.remote.toggle',
          ),
          _field(
            'remote_run:$i',
            '立即触发 ${v['id']}',
            '',
            false,
            'wb.automation.remote.run',
          ),
          _field(
            'remote_remove:$i',
            '删除 ${v['id']}',
            '',
            false,
            'wb.automation.remote.remove',
          ),
          _field(
            'remote_edit:$i',
            '编辑 ${v['id']}',
            '',
            false,
            'client.remote.edit',
          ),
        ],
        _field('runs', jsonEncode(await request('tasks')), '', false),
      ],
      {'handle': handle, 'remote_items': values, 'settings': data},
    );
  }

  Future<Map<String, Object?>> _mediaPanel(
    String op,
    String id,
    String scope,
    Map<String, dynamic> a,
  ) async {
    final settings = container.read(settingsControllerProvider).requireValue;
    if (op == 'wb.media.text') {
      final item = await container
          .read(libraryRepositoryProvider)
          .getById(requiredString(a, 'item_id'));
      if (item == null) throw const BridgeFailure('not_found', '创作已不存在');
      final bytes = await container
          .read(libraryRepositoryProvider)
          .readBytes(item);
      return _textPanel(
        item.name,
        utf8.decode(bytes ?? [], allowMalformed: true),
      );
    }
    if (op == 'wb.media.history') {
      if (a['generation_id'] != null) {
        final record = await container
            .read(generationRepositoryProvider)
            .get(a['generation_id'] as String);
        final item = record?.libraryItemId == null
            ? null
            : await container
                  .read(libraryRepositoryProvider)
                  .getById(record!.libraryItemId!);
        final bytes = item == null
            ? null
            : await container.read(libraryRepositoryProvider).readBytes(item);
        if (bytes == null) {
          throw const BridgeFailure('not_found', '图片文件不存在');
        }
        final dir = await Directory.systemTemp.createTemp('expert-history-');
        final file = File(p.join(dir.path, item!.name));
        await file.writeAsBytes(bytes);
        return _panel('创作历史', [
          _field('path', '路径', file.path),
          _field('__preview', '预览', '', false, 'wb.media.preview'),
        ]);
      }
      final rows = await container.read(generationRepositoryProvider).list();
      final texts = (await container.read(libraryRepositoryProvider).list())
          .where((i) => i.name.startsWith('创作-') && i.mimeType == 'text/plain');
      return _panel('创作历史', [
        for (final item in texts.take(30))
          _field('creation:${item.id}', item.name, '', false, 'wb.media.text'),
        for (final r in rows.take(60))
          _field(
            'generation:${r.id}',
            '${r.createdAt} ${r.originalPrompt}',
            '',
            false,
            'wb.media.history',
          ),
      ]);
    }
    if (op == 'wb.media' || op == 'wb.voice') {
      return _panel(op == 'wb.voice' ? '语音' : '创作与媒体', [
        _field('__history', '查看创作历史', '', false, 'wb.media.history'),
        _field('text', '文本 / 提示词'),
        _field('path', '音频文件绝对路径'),
        _field('__image', '生成图片', '', false, 'wb.media.image'),
        _field('__write', '创作文本（独立窗口）', '', false, 'wb.media.write'),
        _field('__asr', '识别音频，预览后使用', '', false, 'wb.voice.asr'),
        _field('__tts', '朗读上述文本', '', false, 'wb.voice.tts'),
        _field('__record', '开始录音', '', false, 'wb.voice.record'),
        _field('__stop', '停止录音并识别', '', false, 'wb.voice.stop'),
      ]);
    }
    if (op == 'wb.voice.send') {
      final text = requiredString(a, 'text');
      if (controller.isConversationRunning(id)) {
        await controller.addWorkRequirement(id, text);
      } else {
        unawaited(controller.sendToSession(id, text));
      }
      return _textPanel('已提交', '语音文本已提交到当前主任务。');
    }
    if (op == 'wb.media.write') {
      return _sideCommand('wb.side.open', id, scope, {
        'text': requiredString(a, 'text'),
        'creative': true,
      });
    }
    if (op == 'wb.voice.record') {
      final key = '$scope:$id';
      if (_voiceCaptures.containsKey(key)) {
        throw const BridgeFailure('busy', '已经在录音');
      }
      final dir = await Directory.systemTemp.createTemp('expert-recording-');
      final path = p.join(dir.path, 'recording.wav'),
          quoted = path.replaceAll("'", "''");
      final script =
          "Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class AudioCapture { [DllImport(\"winmm.dll\",CharSet=CharSet.Unicode)] public static extern int mciSendString(string a,System.Text.StringBuilder b,int c,IntPtr d); }'; if([AudioCapture]::mciSendString('open new type waveaudio alias capture',\$null,0,[IntPtr]::Zero)-ne 0){throw 'microphone unavailable'}; if([AudioCapture]::mciSendString('record capture',\$null,0,[IntPtr]::Zero)-ne 0){throw 'recording failed'}; [Console]::WriteLine('READY'); [Console]::ReadLine()|Out-Null; [AudioCapture]::mciSendString('stop capture',\$null,0,[IntPtr]::Zero)|Out-Null; [AudioCapture]::mciSendString('save capture \"$quoted\"',\$null,0,[IntPtr]::Zero)|Out-Null; [AudioCapture]::mciSendString('close capture',\$null,0,[IntPtr]::Zero)|Out-Null";
      final proc = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      final ready = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((s) => s.trim() == 'READY');
      proc.stderr.drain<void>();
      try {
        await ready.timeout(const Duration(seconds: 5));
      } catch (_) {
        proc.kill();
        throw const BridgeFailure('recording_failed', '无法打开录音设备');
      }
      _voiceCaptures[key] = (proc, path);
      return _panel('正在录音', [
        _field('__stop', '停止录音并识别', '', false, 'wb.voice.stop'),
      ]);
    }
    if (op == 'wb.voice.stop') {
      final value = _voiceCaptures.remove('$scope:$id');
      if (value == null) {
        throw const BridgeFailure('not_found', '当前没有录音');
      }
      value.$1.stdin.writeln();
      await value.$1.stdin.close();
      await value.$1.exitCode.timeout(const Duration(seconds: 10));
      if (!settings.asrConfigured) {
        return _panel('录音已保存（尚未配置 ASR）', [
          _field('path', '录音文件', value.$2),
          _field('__preview', '播放录音', '', false, 'wb.media.preview'),
        ]);
      }
      return _mediaPanel('wb.voice.asr', id, scope, {'path': value.$2});
    }
    return _startJob(scope, id, '媒体处理', (job) async {
      final api = container.read(mediaApiProvider);
      if (op == 'wb.media.image') {
        final result = await api.generateImage(
          config: settings.imageGenerationApi,
          apiKey: settings.imageGenerationApiKey,
          prompt: requiredString(a, 'text'),
          cancelToken: job.token,
        );
        if (result.base64 != null) {
          final dir = await Directory.systemTemp.createTemp('expert-media-');
          final file = File(p.join(dir.path, 'image.png'));
          await file.writeAsBytes(base64Decode(result.base64!));
          await container
              .read(generationRepositoryProvider)
              .record(
                output: Attachment(
                  name: 'image.png',
                  mimeType: result.mimeType,
                  imageBase64: result.base64,
                ),
                config: settings.imageGenerationApi,
                originalPrompt: requiredString(a, 'text'),
                sentPrompt: requiredString(a, 'text'),
                conversationId: id,
                messageId: job.id,
              );
          return _panel('图片已生成', [
            _field('path', '文件', file.path),
            _field('__preview', '预览', '', false, 'wb.media.preview'),
          ]);
        }
        return _textPanel('图片已生成', result.remoteUrl ?? '未返回图片');
      }
      if (op == 'wb.voice.asr') {
        final file = File(requiredString(a, 'path'));
        if (await file.length() > 25 * 1024 * 1024) {
          throw const BridgeFailure('too_large', '音频超过 25 MiB');
        }
        final text = await api.transcribeSpeech(
          config: settings.asrApi,
          apiKey: settings.asrApiKey,
          audioBytes: await file.readAsBytes(),
          mimeType: 'audio/${p.extension(file.path).replaceFirst('.', '')}',
          filename: p.basename(file.path),
          cancelToken: job.token,
        );
        return _panel(
          '语音识别（不会自动发送）',
          [
            _field('text', '识别文本', text),
            _field('__copy', '复制识别结果', '', false, 'client.copy'),
            _field('__send', '发送到当前主任务', '', false, 'wb.voice.send'),
            _field('__side', '在旁问中使用', '', false, 'wb.media.write'),
          ],
          {'output': text},
        );
      }
      if (op == 'wb.voice.tts') {
        final audio = await api.synthesizeSpeech(
          config: settings.ttsApi,
          apiKey: settings.ttsApiKey,
          text: requiredString(a, 'text'),
          cancelToken: job.token,
        );
        final dir = await Directory.systemTemp.createTemp('expert-speech-');
        final file = File(p.join(dir.path, 'speech.${audio.fileExtension}'));
        await file.writeAsBytes(audio.bytes);
        final safe = file.path.replaceAll("'", "''");
        final player = await Process.start('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Add-Type -AssemblyName presentationCore; \$p=New-Object System.Windows.Media.MediaPlayer; \$p.Open([uri]'$safe'); \$p.Play(); Start-Sleep -Milliseconds 600; while(\$p.Position -lt \$p.NaturalDuration.TimeSpan){Start-Sleep -Milliseconds 100}",
        ]);
        job.token.whenCancel.then((_) {
          player.kill();
        });
        final result = await player.exitCode;
        if (result != 0 && !job.token.isCancelled) {
          throw const BridgeFailure('playback_failed', '播放器未正常结束');
        }
        return _textPanel('朗读结束', file.path);
      }
      if (op == 'wb.media.preview') {
        final path = requiredString(a, 'path');
        if (!{
          '.png',
          '.jpg',
          '.jpeg',
          '.gif',
          '.webp',
          '.bmp',
          '.pdf',
          '.mp3',
          '.wav',
          '.mp4',
          '.webm',
          '.html',
        }.contains(p.extension(path).toLowerCase())) {
          throw const BridgeFailure('unsupported', '只能预览图片、文档或媒体');
        }
        await Process.start('explorer.exe', [
          path,
        ], mode: ProcessStartMode.detached);
        return _textPanel('预览', '已打开预览窗口');
      }
      throw const BridgeFailure('unsupported', '未知媒体操作');
    });
  }

  Future<Map<String, Object?>> _updatePanel(
    String op,
    String id,
    String scope,
    Map<String, dynamic> a,
  ) async {
    final prefs = container.read(sharedPrefsProvider);
    final downloadRoot = Directory(
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
        'expert-chat',
        'releases',
      ),
    );
    if (op == 'wb.update.check') {
      final url = requiredString(a, 'manifest');
      if (Uri.parse(url).scheme != 'https') {
        throw const BridgeFailure('invalid_params', '更新清单须为 HTTPS');
      }
      await prefs.setString('tuiUpdateManifestUrl', url);
      final manifest = (await Dio().get<Map<String, dynamic>>(url)).data!;
      return _panel('可用更新 ${manifest['version']}', [
        _field('url', '下载地址', manifest['url'] as String? ?? ''),
        _field('sha256', 'SHA-256', manifest['sha256'] as String? ?? ''),
        _field('__download', '下载、校验并解包', '', false, 'wb.update.download'),
      ]);
    }
    if (op == 'wb.update.download') {
      return _startJob(scope, id, '下载更新', (job) async {
        final hash = requiredString(a, 'sha256');
        if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash)) {
          throw const BridgeFailure('invalid_params', '必须提供 SHA-256');
        }
        final dir = Directory(
          p.join(
            downloadRoot.path,
            DateTime.now().millisecondsSinceEpoch.toString(),
          ),
        );
        await dir.create(recursive: true);
        final archivePath = await UpdateDownloader().download(
          url: requiredString(a, 'url'),
          fileName: 'expert-$hash.zip',
          expectedSha256: hash,
          cancelToken: job.token,
          onProgress: (got, total) {
            job.output = '已下载 $got / $total 字节';
          },
        );
        final archive = ZipDecoder().decodeBytes(
          await File(archivePath).readAsBytes(),
        );
        if (archive.length > 6000) {
          throw const BridgeFailure('too_large', '更新包文件过多');
        }
        var total = 0;
        for (final item in archive) {
          if (!item.isFile) {
            continue;
          }
          final target = p.normalize(
            p.join(dir.path, item.name.replaceAll('\\', '/')),
          );
          if (!p.isWithin(dir.path, target)) {
            throw const BridgeFailure('invalid_archive', '更新包路径越界');
          }
          total += item.size;
          if (total > 1024 * 1024 * 1024) {
            throw const BridgeFailure('too_large', '更新包解压过大');
          }
          final file = File(target);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(item.content as List<int>);
        }
        return _textPanel('更新已下载', 'SHA-256 校验通过，重新打开 /updates 选择新版本。');
      });
    }
    final package = File(Platform.resolvedExecutable).parent.parent.parent;
    final releases = package.parent.parent;
    final candidates = <String>[];
    if (await releases.exists()) {
      await for (final entry in releases.list()) {
        if (entry is Directory) {
          for (final name in ['ExpertChat-TUI', 'ExpertChat-SharedHost']) {
            final f = File(p.join(entry.path, name, 'expert-tui.exe'));
            if (await f.exists()) {
              candidates.add(f.path);
            }
          }
        }
      }
    }
    if (await downloadRoot.exists()) {
      await for (final entry in downloadRoot.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is File &&
            p.basename(entry.path) == 'expert-tui.exe' &&
            await File(
              p.join(entry.parent.path, 'host', 'bin', 'expert-host.exe'),
            ).exists()) {
          candidates.add(entry.path);
        }
      }
    }
    candidates.sort();
    if (op == 'wb.update.switch') {
      final target = requiredString(a, 'path');
      if (!candidates.contains(target)) {
        throw const BridgeFailure('invalid_params', '请选择已安装完整发行包');
      }
      if (!await File(
        p.join(p.dirname(target), 'host', 'bin', 'expert-host.exe'),
      ).exists()) {
        throw const BridgeFailure('not_found', '发行包缺少 Host');
      }
      final launcher = File(
        p.join(
          Platform.environment['USERPROFILE'] ?? '',
          '.local',
          'bin',
          'expert.cmd',
        ),
      );
      await launcher.copy(
        '${launcher.path}.before-${DateTime.now().millisecondsSinceEpoch}',
      );
      await launcher.writeAsString(
        '@echo off\r\n"$target" %*\r\nexit /b %errorlevel%\r\n',
      );
      return _textPanel('版本已切换', '下次启动 expert 使用：$target\n现有任务不受影响。');
    }
    return _panel(
      '更新与版本',
      [
        _field('current', '当前 Host', Platform.resolvedExecutable, false),
        _field(
          'manifest',
          '更新清单 HTTPS 地址',
          prefs.getString('tuiUpdateManifestUrl') ?? '',
        ),
        _field('__check', '检查更新', '', false, 'wb.update.check'),
        _field('path', '目标发行包 TUI 路径', p.join(package.path, 'expert-tui.exe')),
        _field('__switch', '切换版本 / 回退', '', false, 'wb.update.switch'),
        for (final (i, path) in candidates.indexed)
          _field('version:$i', path, '', false, 'wb.update.choose'),
      ],
      {'versions': candidates},
    );
  }
}
