part of 'backend.dart';

extension ContextSearchCommands on ControllerBridgeBackend {
  Future<Map<String, Object?>?> _contextSearchCommand(
    String method,
    Map<String, dynamic> args,
  ) async {
    final topic = args[method == 'terminal.query' ? 'topic' : 'action'];
    if (method == 'terminal.query' && topic == 'search.all') {
      return _searchArchive(args);
    }
    if (!((method == 'terminal.query' && topic == 'context.contents') ||
        (method == 'terminal.action' && topic == 'context.selection.set'))) {
      return null;
    }
    final id = requiredString(args, 'session_id');
    _session(id);
    await controller.loadSession(id);
    if (method == 'terminal.action') {
      _idle(id);
      final key = requiredString(args, 'key');
      final current = await _contextContents(id);
      if ((current['entries'] as List).any(
        (e) => e['key'] == key && e['locked'] == true,
      )) {
        throw const BridgeFailure('invalid_params', '最新用户轮始终保留，不能排除');
      }
      if (!(current['entries'] as List).any((e) => e['key'] == key)) {
        throw const BridgeFailure('not_found', '上下文项已改变，请重新打开');
      }
      await container
          .read(contextSelectionsProvider.notifier)
          .toggle(id, key, args['enabled'] == true);
    }
    return _contextContents(id);
  }

  Future<Map<String, Object?>> _contextContents(String id) async {
    final conversation = _session(id), path = conversation.activePath;
    final selection =
        container.read(contextSelectionsProvider)[id] ??
        const ContextSelection();
    const counter = ContextWindowManager();
    final settings = container.read(settingsControllerProvider).requireValue;
    final prefs = effectiveContextPrefs(settings, _terminalModel(id));
    final entries = <Map<String, Object?>>[
      {
        'key': 'project',
        'kind': 'section',
        'name': '项目资料与说明',
        'enabled': selection.includeProject,
        'estimated_tokens': null,
      },
      {
        'key': 'memory',
        'kind': 'section',
        'name': '任务记忆与固定要求',
        'enabled': selection.includeMemory,
        'estimated_tokens': null,
      },
    ];
    final latestUser = path
        .where((m) => m.role == MessageRole.user)
        .lastOrNull
        ?.id;
    var round = '', roundNumber = 0;
    final rounds = <String, List<ChatMessage>>{};
    for (final message in path) {
      if (message.role == MessageRole.user || round.isEmpty) {
        round = message.id;
        roundNumber++;
        rounds[round] = [];
        entries.add({
          'key': 'round:$round',
          'kind': 'round',
          'name': '第 $roundNumber 轮 · ${_contextExcerpt(message.content, 90)}',
          'message_id': message.id,
          'enabled':
              round == latestUser || !selection.excludedRounds.contains(round),
          'locked': round == latestUser,
          'estimated_tokens': 0,
        });
      }
      rounds[round]!.add(message);
      for (final file in message.attachments) {
        final key = ContextSelection.attachmentKey(message, file);
        entries.add({
          'key': 'file:$key',
          'kind': 'file',
          'round_id': round,
          'name': '  文件 · ${file.name}',
          'enabled': !selection.excludedAttachments.contains(key),
          'parent_enabled':
              round == latestUser || !selection.excludedRounds.contains(round),
          'estimated_tokens': file.hasImageData
              ? 1200
              : counter.estimateTextTokens(file.text),
        });
      }
      for (final step in message.searchActivities) {
        if (step.resultText?.isNotEmpty != true) continue;
        final key = ContextSelection.toolKey(message, step);
        entries.add({
          'key': 'tool:$key',
          'kind': 'tool',
          'round_id': round,
          'name': '  工具结果 · ${_contextExcerpt(step.query, 80)}',
          'enabled': selection.includedTools.contains(key),
          'parent_enabled':
              round == latestUser || !selection.excludedRounds.contains(round),
          'estimated_tokens': counter.estimateTextTokens(
            '${step.query}\n${step.resultText}',
          ),
        });
      }
    }
    for (final entry in entries.where((e) => e['kind'] == 'round')) {
      final messages = rounds[(entry['key'] as String).substring(6)]!;
      entry['estimated_tokens'] = messages.fold<int>(
        0,
        (n, m) => n + 6 + counter.estimateTextTokens(m.content),
      );
    }
    final filtered = selection.filter(path);
    final historyTokens = counter.estimateStoredMessagesTokens(filtered);
    final toolTokens = counter.estimateTextTokens(
      selection.toolReferences(path),
    );
    final insight = container.read(workSessionInsightsProvider)[id];
    final parts = <String, int>{
      'system': 0,
      'conversation': 0,
      'tool_results': 0,
    };
    for (final message in insight?.messages ?? const <LlmRequestMessage>[]) {
      final key = message.role == MessageRole.system
          ? 'system'
          : message.role == MessageRole.tool
          ? 'tool_results'
          : 'conversation';
      parts[key] = parts[key]! + counter.estimateMessageTokens(message);
    }
    return {
      'title': '上下文内容选择',
      'session_id': id,
      'entries': entries,
      'input_budget': prefs.inputBudgetTokens,
      'selected_estimate': historyTokens + toolTokens,
      'history_estimate': historyTokens,
      'tool_estimate': toolTokens,
      'last_request_parts': parts,
      'last_request_tokens': state.contextReports[id]?.sentTokens,
      'history_limit': prefs.maxHistoryMessages,
      'notice':
          '勾选只影响下一次生成；原记录保留。最新输入始终携带。工具结果按需选入，正在执行的工具调用与结果保持成对。占用为估算，系统提示与工具定义另计。',
    };
  }

  String _contextExcerpt(String value, int limit) {
    final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > limit ? '${text.substring(0, limit)}…' : text;
  }

  Future<Map<String, Object?>> _searchArchive(Map<String, dynamic> args) async {
    final query = (args['query'] as String? ?? '').trim();
    final offset = ((args['offset'] as num?)?.toInt() ?? 0).clamp(0, 100000);
    const pageSize = 40;
    if (query.isEmpty) {
      return {
        'query': query,
        'hits': <Object>[],
        'offset': 0,
        'has_more': false,
      };
    }
    if (query.length > 500) {
      throw const BridgeFailure('invalid_params', '搜索文字最多 500 个字符');
    }
    final needle = query.toLowerCase();
    final repo = container.read(conversationRepositoryProvider);
    final summaries = await repo.loadSummaries();
    final active = {for (final c in state.conversations) c.id: c};
    final ids = {...summaries.map((c) => c.id), ...active.keys}.toList();
    final times = {
      for (final c in summaries) c.id: c.updatedAt,
      for (final c in active.values) c.id: c.updatedAt,
    };
    ids.sort((a, b) => times[b]!.compareTo(times[a]!));
    final hits = <Map<String, Object?>>[];
    var skipped = 0;
    String snippet(String body, int at) {
      final start = (at - 50).clamp(0, body.length),
          end = (at + query.length + 130).clamp(0, body.length);
      return '${start > 0 ? '…' : ''}${body.substring(start, end).replaceAll(RegExp(r'\s+'), ' ')}${end < body.length ? '…' : ''}';
    }

    for (final id in ids) {
      final loaded = active[id];
      Conversation conversation;
      try {
        conversation = loaded?.messagesLoaded == true
            ? loaded!
            : await repo.loadConversation(id);
      } catch (_) {
        skipped++;
        continue;
      }
      final visible = conversation.activePath.map((m) => m.id).toSet();
      var sessionMatched = false;
      for (final message in conversation.messages.reversed) {
        final sources = <({String kind, String body})>[
          (kind: '正文', body: message.content),
          for (final file in message.attachments)
            (kind: '附件 · ${file.name}', body: '${file.name}\n${file.text}'),
          for (final step in message.searchActivities)
            (
              kind: '工具 · ${step.toolName ?? step.kind.name}',
              body:
                  '${step.query}\n${step.resultText ?? ''}\n${step.error ?? ''}',
            ),
        ];
        for (final source in sources) {
          final at = source.body.toLowerCase().indexOf(needle);
          if (at < 0) continue;
          sessionMatched = true;
          hits.add({
            'session_id': id,
            'message_id': message.id,
            'title': conversation.title,
            'role': message.role.name,
            'kind': source.kind,
            'snippet': snippet(source.body, at),
            'active_branch': visible.contains(message.id),
            'preview': source.body.length > 12000
                ? '${source.body.substring(0, 12000)}\n[预览截断]'
                : source.body,
            'updated_at': conversation.updatedAt.toUtc().toIso8601String(),
          });
          if (hits.length > offset + pageSize) break;
        }
        if (hits.length > offset + pageSize) break;
      }
      if (!sessionMatched &&
          conversation.title.toLowerCase().contains(needle)) {
        hits.add({
          'session_id': id,
          'message_id': '',
          'title': conversation.title,
          'role': '',
          'kind': '会话标题',
          'snippet': conversation.title,
          'active_branch': true,
          'preview': conversation.title,
        });
      }
      if (hits.length > offset + pageSize) break;
    }
    return {
      'query': query,
      'hits': hits.skip(offset).take(pageSize).toList(),
      'offset': offset,
      'has_more': hits.length > offset + pageSize,
      'page_size': pageSize,
      'skipped_sessions': skipped,
    };
  }
}
