part of 'backend.dart';

extension TerminalCommands on ControllerBridgeBackend {
  Map<String, Object?> _workspacePermissions(DesktopWorkspace workspace) => {
    ..._workspace(workspace),
    'scopes': [
      for (final scope in workspace.scopes)
        {
          'name': scope.name,
          'path': scope.path,
          'access': scope.access.wireValue,
        },
    ],
  };

  Future<Map<String, Object?>> _workspacePermissionCommand(
    String method,
    Map<String, dynamic> args,
  ) async {
    final workspaceId = requiredString(args, 'workspace_id');
    final host = container.read(desktopWorkspaceHostProvider);
    final workspaces = await host.list();
    final workspace = workspaces.where((w) => w.id == workspaceId).firstOrNull;
    if (workspace == null) {
      throw const BridgeFailure('not_found', '本机工作区不存在，请重新打开工作区列表');
    }
    if (method == 'terminal.query') {
      return {'workspace': _workspacePermissions(workspace)};
    }
    if (args['confirmed'] != true) {
      throw const BridgeFailure('confirmation_required', '请确认目录与新的访问权限');
    }
    final name = requiredString(args, 'name');
    final scope = workspace.scopes.where((s) => s.name == name).firstOrNull;
    if (scope == null) {
      throw const BridgeFailure('not_found', '目录规则已被删除，请重新打开权限页面');
    }
    if (args['expected_access'] != scope.access.wireValue ||
        args['expected_path'] != scope.path) {
      throw const BridgeFailure('conflict', '目录规则已变化，请重新打开权限页面');
    }
    final rawAccess = requiredString(args, 'access');
    final access = WorkspaceAccess.values
        .where((value) => value.wireValue == rawAccess)
        .firstOrNull;
    if (access == null) {
      throw const BridgeFailure('invalid_params', '请选择只读、读写或拒绝访问');
    }
    // Duplicate historical registrations can refer to the same directory.
    final affectedIds = workspaces
        .where(
          (w) =>
              workspacePathIdentity(w.root) ==
              workspacePathIdentity(workspace.root),
        )
        .map((w) => w.id)
        .toSet();
    final bindings = container.read(conversationWorkspaceBindingsProvider);
    for (final entry in bindings.entries.where(
      (e) => affectedIds.contains(e.value),
    )) {
      _idle(entry.key);
    }
    final updated = await host.setScope(
      workspace: workspace.id,
      name: scope.name,
      path: scope.path,
      access: access,
    );
    _workspaceCache = null;
    for (final entry in bindings.entries.where(
      (e) => e.value == workspace.id,
    )) {
      container.read(workApprovalsProvider.notifier).revokeSession(entry.key);
    }
    return {
      'workspace': _workspacePermissions(updated),
      'notice': '已将 ${name == 'root' ? '根目录' : name} 改为${access.label}',
    };
  }

  Map<String, Object?> _terminalUsage(String id) {
    final value = container.read(workSessionInsightsProvider)[id];
    if (value == null) {
      return {
        'available': false,
        'speed': StreamTokenMeter.latest[id]?.snapshot(),
      };
    }
    final estimate = estimateWorkCost(
      value,
      container.read(modelPricingProvider),
    );
    return {
      'available': true,
      'speed': StreamTokenMeter.latest[id]?.snapshot(),
      'input': value.inputTokens,
      'output': value.outputTokens,
      'cached': value.cachedTokens,
      'cache_complete': value.cacheComplete,
      'unknown': value.requests.values.where((v) => v == null).length,
      'requests': value.requests.length,
      'cost': value.cost ?? estimate?.amount,
      'currency': value.currency ?? estimate?.currency,
      'estimated': value.cost == null,
      'complete': value.cost != null || estimate?.complete == true,
    };
  }

  String _terminalDigest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  LlmConfig _terminalModel(String id) {
    final settings = container.read(settingsControllerProvider).requireValue;
    final choice = container.read(conversationModelChoiceProvider)[id];
    final parsed = parseModelSourceChoice(choice ?? '');
    final profile = parsed == null
        ? settings.active
        : settings.profiles.where((p) => p.id == parsed.profile).firstOrNull;
    return LlmConfig(
      baseUrl: profile?.baseUrl ?? settings.baseUrl,
      apiKey: '',
      model:
          parsed?.model ??
          (choice != null && !choice.startsWith('__')
              ? choice
              : settings.model),
      profileId: profile?.id,
      apiFormat: profile?.apiFormat ?? settings.apiFormat,
      authMode: profile?.authMode ?? 'apiKey',
    );
  }

  bool _terminalModelAmbiguous(String id) {
    final choice = container.read(conversationModelChoiceProvider)[id];
    // Explicit source choices also start with '__'; only unresolved selectors
    // must be rejected when editing settings for one endpoint/model pair.
    return choice != null &&
        choice.startsWith('__') &&
        parseModelSourceChoice(choice) == null;
  }

  /// Whether this session's concrete model can use fast (priority) mode.
  bool _fastSupported(String id) =>
      !_terminalModelAmbiguous(id) && _terminalModel(id).supportsPriorityTier;
  Map<String, Object?> _terminalPanel(String title, Iterable<String> lines) => {
    'title': title,
    'lines': lines.toList(),
  };
  Future<Map<String, Object?>> _terminalCommand(
    String method,
    Map<String, dynamic> a,
  ) async {
    final imported = await _externalSessionCommand(method, a);
    if (imported != null) return imported;
    final contextSearchResult = await _contextSearchCommand(method, a);
    if (contextSearchResult != null) return contextSearchResult;
    final id = a['session_id'] as String?;
    final topic = requiredString(
      a,
      method == 'terminal.query' ? 'topic' : 'action',
    );
    if (id != null) _session(id);
    if ((method == 'terminal.query' && topic == 'workspace.permissions') ||
        (method == 'terminal.action' && topic == 'workspace.permission.set')) {
      return _workspacePermissionCommand(method, a);
    }
    final settings = container.read(settingsControllerProvider).requireValue;
    if (method == 'terminal.query') {
      if (topic == 'status' || topic == 'doctor') {
        final lines = <String>[
          '执行端：${this is PersistentBridgeHost ? '独立 Dart Host' : '内嵌执行端'} · PID $pid',
          '会话：${id ?? '未建立'}',
          '活动任务：${controller.runningConversationIds.length}',
          '可用模型：${_models().length}',
          '模型来源：${settings.profiles.length}',
          if (id != null)
            '当前模型：${_modelLabel(container.read(conversationModelChoiceProvider)[id], settings.model)}',
        ];
        if (topic == 'doctor') {
          try {
            await container
                .read(appDatabaseProvider)
                .customSelect('SELECT 1')
                .get();
            lines.add('数据库：可读取');
          } catch (_) {
            lines.add('数据库：读取失败');
          }
          try {
            final workspaces = await _workspaces();
            lines.add('文件服务：可访问，${workspaces.length} 个工作区');
          } catch (_) {
            lines.add('文件服务：不可用，请核对完整发行包');
          }
          lines.add('未调用付费模型；此诊断不测试远端 API。');
        }
        if (id != null) {
          lines.add('状态：${_status(_session(id))}');
          final pending = controller.pendingSessionConfigFor(id);
          if (pending != null) lines.add('待下轮生效：${pending.labels.join('、')}');
        }
        return _terminalPanel(topic == 'doctor' ? '环境诊断' : '运行状态', lines);
      }
      if (id == null) throw const BridgeFailure('invalid_params', '请先选择会话');
      await controller.loadSession(id);
      if (topic == 'step.detail') {
        final stepId = requiredString(a, 'step_id');
        for (final message in _session(id).messages) {
          for (final activity in message.searchActivities) {
            if (activity.id != stepId) continue;
            final blocked = _blockedApproval(id, activity);
            return {
              'step': {
                'id': activity.id,
                'message_id': message.id,
                'round_id': activity.roundId,
                'verb': _verb(activity.toolName),
                'tool': activity.toolName,
                'object': TuiSnapshotEvidence.stepObject(activity),
                'status': activity.interrupted
                    ? 'stopped'
                    : blocked
                    ? 'approval'
                    : activity.status.name,
                'input': activity.toolArguments,
                'result': blocked ? '等待批准，尚未执行' : activity.resultText ?? '',
                'detail': activity.error,
                'exit_code': _exitCode(activity.resultText),
                'elapsed_ms': activity.startedAt == null
                    ? null
                    : (activity.finishedAt ?? DateTime.now())
                          .difference(activity.startedAt!)
                          .inMilliseconds,
              },
            };
          }
        }
        throw const BridgeFailure('not_found', '此工具步骤已不存在');
      }
      if (topic == 'context') {
        final config = _terminalModel(id),
            prefs = effectiveContextPrefs(settings, _terminalModel(id));
        final report = state.contextReports[id],
            insight = container.read(workSessionInsightsProvider)[id];
        return {
          'contents': await _contextContents(id),
          ..._terminalPanel('模型上下文', [
            '模型：${config.model}',
            '窗口：${prefs.contextWindowTokens} tokens',
            '输入预算：${prefs.inputBudgetTokens} tokens',
            '输出预留：${prefs.effectiveOutputReserve} tokens',
            '最近请求输入：${report?.sentTokens ?? '尚无统计'} tokens',
            '历史消息上限：${prefs.maxHistoryMessages}',
            '当前请求消息：${insight?.messages.length ?? 0}，工具：${insight?.tools.length ?? 0}',
            '设置只约束本地发送预算，不能扩大提供商实际支持的窗口。',
            '运行中的任务将在完整工具轮结束后应用新设置。',
          ]),
          'context': prefs.toJson(),
          'output_auto':
              (settings.modelContexts[modelContextKey(
                        config.baseUrl,
                        config.model,
                      )] ??
                      settings.context)
                  .maxOutputTokens ==
              0,
          'output_limit_known':
              reportedModelLimits(settings, config)?.maxOutputTokens != null,
          'model_key': modelContextKey(config.baseUrl, config.model),
          'automatic': !settings.modelContexts.containsKey(
            modelContextKey(config.baseUrl, config.model),
          ),
        };
      }
      if (topic == 'usage') {
        final value = container.read(workSessionInsightsProvider)[id];
        if (value == null) {
          return {
            ..._terminalPanel('用量与费用', ['此会话尚无用量记录。']),
            'usage': {'available': false},
          };
        }
        final estimate = estimateWorkCost(
          value,
          container.read(modelPricingProvider),
        );
        return {
          ..._terminalPanel('用量与费用', [
            '速度：↑ 输入发送 / ↓ 输出接收，约数按文本估算；缓存与用量仍采用提供商报告。',
            '输入仅在多个上传进度采样之间测量，无法测量时显示 —；不使用整轮耗时代替上传耗时。',
            '任务请求：${value.countRequests(WorkRequestKind.task)}',
            '标题请求：${value.countRequests(WorkRequestKind.title)}',
            '其他辅助请求：${value.countRequests(WorkRequestKind.auxiliary)}',
            '已报告输入：${value.inputTokens} tokens',
            '已报告输出：${value.outputTokens} tokens',
            '缓存输入：${value.cachedTokens} tokens',
            '缓存统计：${value.cacheComplete ? '完整' : '部分请求未报告，已知缓存合计不代表全部'}',
            '参考价更新：2026-10-27；自定义价格优先，其次官方常用模型参考价。',
            'GPT 订阅的 API 参考费用不等于订阅额外扣款；是否扣费以提供商账单为准。',
            'DeepSeek 按峰值参考价估算（非高峰为一半）；未包含缓存写入、区域加价、工具费及代理商差价。',
            '可用 /price 输入单价 输出单价 缓存单价 [币种] 设置当前模型每百万 token 价格。',
            '未报告用量的请求：${value.requests.values.where((v) => v == null).length}',
            value.cost != null
                ? '提供商报告费用：${value.cost} ${value.currency}'
                : estimate != null
                ? '本地估算：${estimate.amount.toStringAsFixed(6)} ${estimate.currency}${estimate.complete ? '' : '（不完整）'}'
                : '费用未知：提供商未报告且没有可用的完整定价。',
            '按 Session 累计并保存，包含任务、标题和辅助请求；升级前未保存的历史用量无法补算。缓存是输入的子集，不重复计费。',
          ]),
          'usage': _terminalUsage(id),
          'request_types': {
            'task': value.countRequests(WorkRequestKind.task),
            'title': value.countRequests(WorkRequestKind.title),
            'auxiliary': value.countRequests(WorkRequestKind.auxiliary),
          },
        };
      }
      if (topic == 'memory') {
        return {
          'title': '当前任务记忆',
          'memory': container.read(workMemoryProvider).snapshot(id),
        };
      }
      if (topic == 'skills') {
        return {
          'title': '技能',
          'skills': [
            for (final skill in settings.chatSkills.skills)
              {...skill.toJson(), 'version': _terminalDigest(skill.toJson())},
          ],
        };
      }
      if (topic == 'hooks') {
        final hooks = container.read(workHooksProvider);
        final binding = container.read(
          conversationWorkspaceBindingsProvider,
        )[id];
        final workspace = (await _workspaces())
            .where((w) => w.id == binding)
            .firstOrNull;
        return {
          'title': '自动化规则',
          'root': workspace?.root ?? hooks.boundRoot(id),
          'hooks': [
            for (final hook in hooks.records)
              if (hook.definition.conversationId == id)
                {
                  ...hook.definition.toJson(),
                  'status': hook.status,
                  'error': hook.error,
                  'version': _terminalDigest(hook.definition.toJson()),
                },
          ],
        };
      }
      if (topic == 'export') {
        final conversation = _session(id),
            buffer = StringBuffer(
              '# ${_session(id).title}\n\nSession: $id\n\n',
            );
        for (final message in conversation.activePath) {
          buffer.writeln('## ${message.role.name}\n\n${message.content}\n');
          for (final file in message.attachments) {
            buffer.writeln('附件：${file.name}\n');
          }
        }
        return {'text': buffer.toString(), 'title': '导出会话'};
      }
      if (topic == 'library') {
        final library = container.read(libraryRepositoryProvider),
            projects = container.read(projectRepositoryProvider);
        final root = await library.folderPath,
            counts = await projects.fileCounts();
        return {
          'title': '资料库',
          'assets': [
            for (final item in await library.list())
              {
                'id': item.id,
                'name': item.name,
                'kind': item.kind.name,
                'mime': item.mimeType,
                'size': item.sizeBytes,
                'path': p.join(root, validateLibraryPath(item.relativePath)),
                'created_at': item.createdAt.toUtc().toIso8601String(),
                'last_used_at': item.lastUsedAt.toUtc().toIso8601String(),
              },
          ],
          'sets': [
            for (final set in await projects.list())
              {
                'id': set.id,
                'name': set.name,
                'count': counts[set.id] ?? 0,
                'updated_at': set.updatedAt.toUtc().toIso8601String(),
              },
          ],
        };
      }
      if (topic == 'library.set') {
        final projects = container.read(projectRepositoryProvider);
        final set = await projects.get(requiredString(a, 'set_id'));
        if (set == null) throw const BridgeFailure('not_found', '资料集不存在');
        final files = await projects.linkedFiles(set.id);
        return _terminalPanel('资料集 · ${set.name}', [
          if (set.instructions.trim().isNotEmpty)
            '说明：${set.instructions.trim()}',
          files.isEmpty ? '资料集中还没有文件。' : '共 ${files.length} 份文件：',
          for (final file in files)
            '${file.name} · ${file.mimeType} · ${file.sizeBytes} bytes',
          '在 GUI 中管理资料集：/gui',
        ]);
      }
      if (topic == 'attachment') {
        final values = _attachmentImports.resolve(
          requiredString(a, '_bridge_client_scope'),
          id,
          requiredString(a, 'token'),
        );
        return _terminalPanel('附件预览', [
          for (final file in values) ...[
            '${file.name} · ${file.mimeType} · ${file.sizeBytes} bytes',
            if (file.hasImageData) '图片已导入，发送时携带图像数据。',
            if (file.text.isNotEmpty)
              file.text.length > 20000
                  ? '${file.text.substring(0, 20000)}\n[预览截断]'
                  : file.text,
          ],
        ]);
      }
      throw const BridgeFailure('unsupported', '未知查询');
    }
    if (id == null) throw const BridgeFailure('invalid_params', '请先选择会话');
    switch (topic) {
      case 'mcp.connect':
      case 'mcp.disconnect':
        if (a['confirmed'] != true) {
          throw const BridgeFailure('confirmation_required', '请确认服务操作');
        }
        final server = _settingsBridge.server(requiredString(a, 'id'));
        if (topic == 'mcp.disconnect') {
          if (controller.runningConversationIds.isNotEmpty) {
            throw const BridgeFailure('busy', '仍有运行任务，请先停止任务再断开共享 MCP 服务');
          }
          await container
              .read(settingsControllerProvider.notifier)
              .setCustomMcpEnabled(server.id, false);
          await container
              .read(mcpClientProvider)
              .disconnectConnection(settings.connectionForCustom(server));
          return {
            'notice': '服务已停用，本机连接已关闭',
            'settings': await _settingsBridge.view(),
          };
        }
        await container
            .read(settingsControllerProvider.notifier)
            .setCustomMcpEnabled(server.id, true);
        final result = await _settingsBridge.invoke('mcp.scan', {
          'id': server.id,
          'confirmed': true,
        });
        return {'notice': '服务发现完成，已更新可用工具', 'settings': result};
      case 'attachment.message.preview':
        final message = _session(
          id,
        ).messages.firstWhere((m) => m.id == a['message_id']);
        final image = message.attachments.firstWhere(
          (v) => v.id == a['attachment_id'],
        );
        if (!image.hasImageData || image.imageBase64 == null) {
          throw const BridgeFailure('not_found', '图片内容不可用');
        }
        final dir = await Directory.systemTemp.createTemp(
          'expert-image-preview-',
        );
        final file = File(
          p.join(
            dir.path,
            'image.${image.mimeType == 'image/jpeg' ? 'jpg' : 'png'}',
          ),
        );
        await file.writeAsBytes(base64Decode(image.imageBase64!));
        await Process.start('explorer.exe', [
          file.path,
        ], mode: ProcessStartMode.detached);
        return {'notice': '已打开图片预览'};
      case 'attachment.preview':
        await _attachmentImports.preview(
          requiredString(a, '_bridge_client_scope'),
          id,
          requiredString(a, 'token'),
        );
        return {'notice': '已打开附件预览'};
      case 'price.set':
        final config = _terminalModel(id);
        if (_terminalModelAmbiguous(id)) {
          throw const BridgeFailure('ambiguous_model', '请先选择具体模型');
        }
        await container
            .read(modelPricingProvider.notifier)
            .save(
              modelPricingKey(config.baseUrl, config.model),
              ModelRate(
                input: (a['input'] as num).toDouble(),
                output: (a['output'] as num).toDouble(),
                cached: (a['cached'] as num).toDouble(),
                currency: a['currency'] as String? ?? 'USD',
              ),
            );
        return {'notice': '当前来源与模型的单价已保存'};
      case 'rename':
        final title = requiredString(a, 'text');
        if (title.length > 200) {
          throw const BridgeFailure('invalid_params', '名称最多 200 字符');
        }
        controller.renameConversation(id, title);
        await controller.persistHostSession(id);
        return {'notice': '会话已改名'};
      case 'pause':
        if (!controller.isConversationRunning(id) || !_session(id).workMode) {
          throw const BridgeFailure('not_running', '当前没有可暂停的工作任务');
        }
        container.read(workRoundsProvider.notifier).requestPause(id);
        return {'notice': '已请求在完整工具轮结束后暂停；已启动的后台进程仍继续'};
      case 'continue':
        final progress = container.read(workRoundsProvider)[id];
        if (progress?.pauseRequested == true || progress?.paused == true) {
          container.read(workRoundsProvider.notifier).resume(id);
          return {'notice': '已继续当前任务'};
        }
        _idle(id);
        _launchTerminalTask(id, () => _resume(id));
        return {'notice': '正在继续当前任务'};
      case 'retry':
        _idle(id);
        if (controller.retryOperationForSession(id) == null) {
          throw const BridgeFailure(
            'not_retryable',
            '没有可重试的失败请求；结果未知的操作不会自动重放',
          );
        }
        _launchTerminalTask(
          id,
          () => controller.runHostCall(id, () => controller.retryLast()),
        );
        return {'notice': '已重试记录中的失败请求'};
      case 'library.delete':
        if (a['confirmed'] != true) {
          throw const BridgeFailure('confirmation_required', '请确认删除素材');
        }
        final library = container.read(libraryRepositoryProvider);
        final item = await library.getById(requiredString(a, 'item_id'));
        if (item == null) throw const BridgeFailure('not_found', '素材已不存在');
        await library.delete(item.id);
        return {'notice': '已从资料库删除 ${item.name}'};
      case 'fast.set':
        final enabled = a['enabled'] == true;
        if (enabled && !_fastSupported(id)) {
          throw const BridgeFailure(
            'unsupported',
            '当前模型来源不支持快速模式；目前只支持 OpenAI 官方 API（api.openai.com）的优先处理',
          );
        }
        await container
            .read(sessionPolicyProvider.notifier)
            .save(id, _policy(id).copyWith(fast: enabled));
        return {
          'notice': enabled
              ? '已开启快速模式：使用 OpenAI 优先处理，响应更快，按优先处理单价计费；下个请求生效'
              : '已关闭快速模式',
        };
      case 'context.set':
        if (_terminalModelAmbiguous(id)) {
          throw const BridgeFailure(
            'ambiguous_model',
            '请先 /model 选定具体来源和模型，再设置窗口',
          );
        }
        final config = _terminalModel(id),
            key = modelContextKey(
              _terminalModel(id).baseUrl,
              _terminalModel(id).model,
            );
        if (a['model_key'] != null && a['model_key'] != key) {
          throw const BridgeFailure('conflict', '模型已切换，请重新打开上下文面板');
        }
        ContextPrefs? prefs;
        if (a['auto'] != true) {
          final current = effectiveContextPrefs(settings, config);
          final window =
              (a['window'] as num?)?.toInt() ?? current.contextWindowTokens;
          if (window < 4096 || window > 2000000) {
            throw const BridgeFailure(
              'invalid_params',
              '窗口须为 4096–2000000 tokens',
            );
          }
          final limit = reportedModelLimits(
            settings,
            config,
          )?.contextWindowTokens;
          if (limit != null && window > limit) {
            throw BridgeFailure('invalid_params', '提供商报告的窗口上限为 $limit tokens');
          }
          if (a['reserve'] is num &&
              ((a['reserve'] as num) < 512 ||
                  (a['reserve'] as num) > window - 1024)) {
            throw const BridgeFailure(
              'invalid_params',
              '输出预留须至少 512，且为输入保留 1024 tokens',
            );
          }
          if (a['history'] is num &&
              ((a['history'] as num) < 0 || (a['history'] as num) > 100000)) {
            throw const BridgeFailure(
              'invalid_params',
              '历史消息须为 0–100000；0 按 Token 预算自动选择',
            );
          }
          if (a['output'] is num &&
              ((a['output'] as num) < 0 ||
                  (a['output'] as num) > window - 1024)) {
            throw const BridgeFailure(
              'invalid_params',
              '输出上限须为 0 或不超过窗口减 1024',
            );
          }
          prefs = ContextPrefs.fromJson({
            ...current.toJson(),
            'contextWindowTokens': window,
            if (a['reserve'] != null) 'reservedOutputTokens': a['reserve'],
            if (a['history'] != null) 'maxHistoryMessages': a['history'],
            if (a['output'] != null) 'maxOutputTokens': a['output'],
          });
        }
        await container
            .read(settingsControllerProvider.notifier)
            .setModelContextPrefs(config.baseUrl, config.model, prefs);
        return {
          'notice': prefs == null
              ? '已恢复自动上下文窗口；下个完整工具轮生效'
              : '已设置 ${prefs.contextWindowTokens} tokens；下个完整工具轮生效',
        };
      case 'memory.save':
        await container.read(workMemoryProvider).checkpoint(id, {
          'expected_revision': a['revision'],
          'user_pins': a['text'] ?? '',
        }, userInitiated: true);
        return {
          'notice': '固定要求已保存，下个完整请求会纳入上下文',
          'revision': container
              .read(workMemoryProvider)
              .snapshot(id)['revision'],
        };
      case 'skill.save':
        final old = settings.chatSkills.skills
            .where((s) => s.id == a['id'])
            .firstOrNull;
        if (old != null && a['version'] != _terminalDigest(old.toJson())) {
          throw const BridgeFailure('conflict', '技能已变化，请重新打开');
        }
        if (old?.fallback == true && a['enabled'] != true) {
          throw const BridgeFailure('invalid_params', '保底技能必须保持启用');
        }
        final skill = ChatSkill(
          id: old?.id ?? const Uuid().v4(),
          name: requiredString(a, 'name'),
          when: a['when'] as String? ?? '',
          prompt: requiredString(a, 'prompt'),
          prefix: a['prefix'] as String? ?? '',
          enabled: a['enabled'] == true,
          fallback: old?.fallback ?? false,
          builtIn: old?.builtIn ?? false,
        );
        await container
            .read(settingsControllerProvider.notifier)
            .setChatSkills(
              ChatSkillCatalog([
                for (final entry in settings.chatSkills.skills)
                  if (entry.id != skill.id) entry,
                skill,
              ]),
            );
        return {
          'notice': '技能已保存',
          'id': skill.id,
          'version': _terminalDigest(skill.toJson()),
        };
      case 'hook.save':
      case 'hook.run':
      case 'hook.remove':
        if (a['confirmed'] != true) {
          throw const BridgeFailure('confirmation_required', '请确认所选自动化规则及命令');
        }
        final runtime = container.read(workHooksProvider);
        final old = runtime.records
            .where(
              (h) =>
                  h.definition.id == a['id'] &&
                  h.definition.conversationId == id,
            )
            .firstOrNull;
        if (old != null &&
            a['version'] != _terminalDigest(old.definition.toJson())) {
          throw const BridgeFailure('conflict', '规则已变化，请重新打开');
        }
        if (topic == 'hook.run') {
          if (old == null) throw const BridgeFailure('not_found', '规则不存在');
          await runtime.runNow(old.definition.id);
        } else if (topic == 'hook.remove') {
          if (old == null) throw const BridgeFailure('not_found', '规则不存在');
          await runtime.remove(old.definition.id);
        } else {
          _idle(id);
          final policy = _policy(id);
          late String root;
          if (policy.sshProfileId.isNotEmpty) {
            final ssh = await container
                .read(researchTerminalProvider.notifier)
                .openWorkSession(policy.sshProfileId, policy.remoteRoot);
            try {
              ssh.validate();
              root = ssh.changeTarget;
            } finally {
              await ssh.close();
            }
          } else {
            final workspaceId = container.read(
              conversationWorkspaceBindingsProvider,
            )[id];
            final workspace = (await _workspaces())
                .where((w) => w.id == workspaceId)
                .firstOrNull;
            if (workspace == null) {
              throw const BridgeFailure('not_found', '请先选择本机工作区');
            }
            root = workspace.root;
          }
          final definition = WorkHookDefinition(
            id: old?.definition.id ?? const Uuid().v4(),
            conversationId: id,
            root: root,
            command: requiredString(a, 'command'),
            watchPath: a['watchPath'] as String? ?? '',
            enabled: a['enabled'] == true,
          );
          await runtime.save(definition);
          return {
            'notice': '自动化规则已保存',
            'id': definition.id,
            'version': _terminalDigest(definition.toJson()),
          };
        }
        return {'notice': '自动化规则已更新'};
      case 'add-dir':
        _idle(id);
        if (a['confirmed'] != true) {
          throw const BridgeFailure('confirmation_required', '请先确认目录与访问权限');
        }
        if (_policy(id).sshProfileId.isNotEmpty) {
          throw const BridgeFailure('unsupported', '此命令用于本机目录授权');
        }
        final workspaceId = container.read(
          conversationWorkspaceBindingsProvider,
        )[id];
        if (workspaceId == null) {
          throw const BridgeFailure('not_found', '请先选择工作区');
        }
        final path = requiredString(a, 'path'),
            name = requiredString(a, 'name');
        if (name == 'root' ||
            !RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(name)) {
          throw const BridgeFailure(
            'invalid_params',
            '别名仅支持字母、数字、_、-，不能为 root',
          );
        }
        if (!p.isAbsolute(path)) {
          throw const BridgeFailure('invalid_params', '请使用绝对目录路径');
        }
        await container
            .read(desktopWorkspaceHostProvider)
            .setScope(
              workspace: workspaceId,
              name: name,
              path: path,
              access: WorkspaceAccess.parse(
                a['access'] as String? ?? 'read-only',
              ),
            );
        _workspaceCache = null;
        return {'notice': '已追加授权目录 $name'};
      case 'init':
        _idle(id);
        _launchTerminalTask(
          id,
          () => controller.sendToSession(
            id,
            '请阅读当前项目，初始化适合本项目的 AGENT.md：写清项目用途、运行、构建、测试命令和代码约定。先检查 AGENT.md、AGENTS.md、CLAUDE.md 等已有规则；存在 AGENT.md 时先读取并提出增量修改，不覆盖既有内容。文件操作遵守当前工具批准策略。${a['text'] ?? ''}',
          ),
        );
        return {'notice': '已开始项目规则初始化，文件操作仍遵守当前批准策略'};
      case 'subagent.start':
        if (_policy(id).planOnly) {
          throw const BridgeFailure('plan_only', '当前为计划模式，请先切换工作模式再启动子代理');
        }
        final effortName = requiredString(a, 'effort');
        final effort = ReasoningEffort.values
            .where((v) => v.name == effortName)
            .firstOrNull;
        if (effort == null) {
          throw const BridgeFailure('invalid_params', '思考强度无效');
        }
        final model = requiredString(a, 'model');
        final available = _models()
            .where(
              (m) =>
                  m['id'] == model ||
                  m['choice'] == model ||
                  '${m['source']}::${m['id']}' == model ||
                  '${m['source_id']}::${m['id']}' == model,
            )
            .toList();
        if (available.length != 1) {
          throw const BridgeFailure(
            'invalid_params',
            '模型不可用或来源不唯一，请使用 来源名称::模型名',
          );
        }
        if (!(available.single['efforts'] as List? ?? []).contains(
          effortName,
        )) {
          throw const BridgeFailure('unsupported', '该模型不支持所选思考强度');
        }
        final task = requiredString(a, 'text');
        final paths = (a['owned_paths'] as List? ?? []).cast<String>();
        _launchTerminalTask(
          id,
          () => controller.startManualSubagent(
            id,
            model: available.single['choice'] as String,
            effort: effort,
            prompt: task,
            ownedPaths: paths,
          ),
        );
        return {'notice': '正在启动手动子代理；完成后回传当前会话'};
      default:
        throw const BridgeFailure('unsupported', '未知终端操作');
    }
  }

  void _launchTerminalTask(String id, Future<dynamic> Function() action) {
    if (!_resuming.add(id)) throw const BridgeFailure('busy', '已有操作正在提交');
    unawaited(
      Future<void>(() async {
        try {
          await action();
        } catch (_) {
          controller.reportExternalFailure(id, '操作未完成，请核对会话状态。');
        } finally {
          _resuming.remove(id);
        }
      }),
    );
  }
}
