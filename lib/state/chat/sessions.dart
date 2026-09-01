part of '../chat_controller.dart';

mixin ChatSessions on ChatTurns {
  /// Start or focus a study-mode conversation (tutor / course-linked).
  Future<Conversation> newStudyConversation({
    required String topic,
    TutorStyle tutorStyle = TutorStyle.mixed,
    StudyPath path = StudyPath.tutor,
    String? courseId,
    String? nodeId,
    String? opener,
  }) async {
    final trimmed = topic.trim();
    final title = trimmed.isEmpty
        ? '学习会话'
        : (trimmed.length <= 24
              ? '学习：$trimmed'
              : '学习：${trimmed.substring(0, 24)}…');
    final sessionTopic = trimmed.isEmpty ? '通用学习' : trimmed;
    final greeting = (opener ?? '').trim().isNotEmpty
        ? opener!.trim()
        : '你好。我们开始学习「${trimmed.isEmpty ? '这个主题' : trimmed}」。'
              '你可以直接提问，或告诉我卡在哪里。需要提示时说「给提示」，需要答案时说「完整讲解」。';
    final openerMsg = ChatMessage(
      role: MessageRole.assistant,
      content: greeting,
      parentId: null,
    );
    final existing = _findUnusedSession(ConversationMode.study);
    if (existing != null) {
      // Reuse blank study shell but always reset opener + meta so a new topic
      // never keeps the previous greeting / tutor style.
      final updated = existing.copyWith(
        title: title,
        authorNote: '',
        messages: [openerMsg],
        activeChildren: {kRootKey: openerMsg.id},
        updatedAt: DateTime.now(),
      );
      _set(
        _s.copyWith(
          conversations: _replace(updated),
          currentId: updated.id,
          error: null,
        ),
      );
      await _persistence.persist();
      await ref
          .read(studyControllerProvider.notifier)
          .upsertSession(
            StudySessionMeta(
              conversationId: updated.id,
              path: path,
              tutorStyle: tutorStyle,
              topic: sessionTopic,
              courseId: courseId,
              nodeId: nodeId,
            ),
          );
      return updated;
    }
    final fresh = Conversation(
      title: title,
      mode: ConversationMode.study,
      messages: [openerMsg],
      activeChildren: {kRootKey: openerMsg.id},
    );
    _set(
      _s.copyWith(
        conversations: [fresh, ..._s.conversations],
        currentId: fresh.id,
        error: null,
      ),
    );
    await _persistence.persist();
    await ref
        .read(studyControllerProvider.notifier)
        .upsertSession(
          StudySessionMeta(
            conversationId: fresh.id,
            path: path,
            tutorStyle: tutorStyle,
            topic: sessionTopic,
            courseId: courseId,
            nodeId: nodeId,
          ),
        );
    return fresh;
  }

  void newConversation() {
    // Chat / story / ensemble are separate: only reuse an unused *chat*.
    // Once a turn has entered preflight, its origin session is reserved even
    // though the user message has not been appended yet. Reusing that blank
    // session here would make “new conversation” keep the same id and let the
    // pending turn appear in the view the user tried to leave.
    final existing = _starting
        ? null
        : _findUnusedSession(ConversationMode.chat);
    if (existing != null) {
      _selectExistingSession(existing);
      return;
    }
    final fresh = Conversation();
    _set(
      _s.copyWith(
        conversations: [fresh, ..._s.conversations],
        currentId: fresh.id,
        error: null,
      ),
    );
    _persistence.persistSoon(_persistence.persist());
  }

  /// Prefer [current] when it already matches; otherwise first unused of [mode]
  /// (unless [currentOnly] is true).
  ///
  /// [characterId] limits single-character stories. [requireLocalCast] /
  /// [forbidLocalCast] distinguish director stories (local cast) from library
  /// single-character stories.
  Conversation? _findUnusedSession(
    ConversationMode mode, {
    String? characterId,
    bool? requireLocalCast,
    bool? forbidLocalCast,
    bool currentOnly = false,
  }) {
    bool matches(Conversation c) {
      if (!c.messagesLoaded) return false;
      if (c.mode != mode || !c.isUnusedSession) return false;
      if (characterId != null && c.characterId != characterId) return false;
      if (requireLocalCast == true && c.localCast.isEmpty) return false;
      if (forbidLocalCast == true && c.localCast.isNotEmpty) return false;
      return true;
    }

    final current = _s.current;
    if (current != null && matches(current)) return current;
    if (currentOnly) return null;
    for (final c in _s.conversations) {
      if (matches(c)) return c;
    }
    return null;
  }

  void _selectExistingSession(Conversation existing) {
    unawaited(selectConversation(existing.id));
  }

  Future<List<String>> _defaultWorldInfoIds() async {
    final entries = await ref.read(worldInfoRepositoryProvider).loadAll();
    return [
      for (final e in entries)
        if (e.enabled) e.id,
    ];
  }

  /// Start a story session bound to [card]. Defaults to all enabled world-info
  /// entries; optional [worldInfoIds] overrides the selection.
  Future<void> newStoryConversation(
    CharacterCard card, {
    List<String>? worldInfoIds,
  }) async {
    // Reuse blank single-character story for the same card (not director cast).
    final existing = _findUnusedSession(
      ConversationMode.story,
      characterId: card.id,
      forbidLocalCast: true,
    );
    if (existing != null) {
      _selectExistingSession(existing);
      return;
    }

    final ids = worldInfoIds ?? await _defaultWorldInfoIds();

    final messages = <ChatMessage>[];
    final activeChildren = <String, String>{};
    final firstMes = card.firstMes.trim();
    if (firstMes.isNotEmpty) {
      final opener = ChatMessage(
        role: MessageRole.assistant,
        content: firstMes,
        parentId: null,
        speakerId: card.id,
        speakerName: card.name,
      );
      messages.add(opener);
      activeChildren[kRootKey] = opener.id;
    }

    final fresh = Conversation(
      title: card.name,
      mode: ConversationMode.story,
      characterId: card.id,
      participantIds: [card.id],
      worldInfoIds: ids,
      messages: messages,
      activeChildren: activeChildren,
    );
    _set(
      _s.copyWith(
        conversations: [fresh, ..._s.conversations],
        currentId: fresh.id,
        error: null,
      ),
    );
    _persistence.persistSoon(_persistence.persist());
  }

  /// Create a story in which the model performs the narrator and every
  /// story-local character while the user acts only as the director.
  Future<void> newDirectorStoryConversation({
    required String title,
    required String premise,
    required List<CharacterCard> cast,
    required String outline,
    String authorNote = '',
    String requirements = '',
    List<String>? worldInfoIds,
    int targetTotalChars = 0,
  }) async {
    final usableCast = cast
        .where((card) => card.name.trim().isNotEmpty)
        .toList();
    if (usableCast.isEmpty) {
      _set(_s.copyWith(error: '导演故事至少需要一个 AI 角色。'));
      return;
    }
    if (outline.trim().isEmpty) {
      _set(_s.copyWith(error: '请先生成或填写故事大纲。'));
      return;
    }

    final ids = worldInfoIds ?? await _defaultWorldInfoIds();
    final premiseText = premise.trim();
    final noteText = authorNote.trim();
    final reqText = requirements.trim();
    final combinedNote = StoryConstraintCompiler.compile(
      premise: premiseText,
      requirements: reqText,
      persistentNote: noteText,
    );
    final resolvedTitle = title.trim().isEmpty
        ? (premiseText.isEmpty ? '导演故事' : premiseText)
        : title.trim();

    // Prefer reusing *current* if it is already an unused director shell
    // (avoid stacking blank director sessions). Always apply the new plan —
    // never return early with stale cast/outline.
    final existing = _findUnusedSession(
      ConversationMode.story,
      requireLocalCast: true,
      currentOnly: true,
    );
    final fresh = existing == null
        ? Conversation(
            title: resolvedTitle,
            mode: ConversationMode.story,
            participantIds: [for (final card in usableCast) card.id],
            localCast: List.unmodifiable(usableCast),
            worldInfoIds: ids,
            outline: outline.trim(),
            authorNote: combinedNote,
            plotCursor: 0,
            targetTotalChars: targetTotalChars < 0 ? 0 : targetTotalChars,
          )
        : existing.copyWith(
            title: resolvedTitle,
            messages: const [],
            activeChildren: const {},
            participantIds: [for (final card in usableCast) card.id],
            localCast: List.unmodifiable(usableCast),
            worldInfoIds: ids,
            outline: outline.trim(),
            authorNote: combinedNote,
            plotCursor: 0,
            targetTotalChars: targetTotalChars < 0 ? 0 : targetTotalChars,
          );

    // The setup draft is cleared immediately after this method succeeds.
    // Persist first so a failed/unfinished disk write cannot lose both copies.
    await _persistence.enqueueWrite(
      () => ref.read(conversationRepositoryProvider).saveConversation(fresh),
    );
    if (existing == null) {
      _set(
        _s.copyWith(
          conversations: [fresh, ..._s.conversations],
          currentId: fresh.id,
          error: null,
        ),
      );
    } else {
      _set(
        _s.copyWith(
          conversations: [
            for (final c in _s.conversations)
              if (c.id == fresh.id) fresh else c,
          ],
          currentId: fresh.id,
          error: null,
        ),
      );
    }
  }

  /// Multi-character ensemble: cast in one [venue], taking turns.
  Future<void> newEnsembleConversation({
    required List<CharacterCard> cast,
    required String venue,
    String authorNote = '',
    List<String>? worldInfoIds,
  }) async {
    if (cast.length < 2) {
      _set(_s.copyWith(error: '角色大乱斗至少需要 2 名角色。'));
      return;
    }
    final ids = worldInfoIds ?? await _defaultWorldInfoIds();
    final place = venue.trim().isEmpty ? '同一空间' : venue.trim();
    final title = cast.map((c) => c.name).take(3).join('·');
    final names = cast.map((c) => c.name).join('、');

    final systemIntro = ChatMessage(
      role: MessageRole.assistant,
      content:
          '【场景】$place\n'
          '【在场】$names\n'
          '你们已聚在一起。可由导演下达指令，或点「下一位发言 / 自动轮流」让角色对谈。',
      speakerName: '旁白',
    );

    // Reuse current unused ensemble shell, but always apply the new cast/venue.
    final existing = _findUnusedSession(
      ConversationMode.ensemble,
      currentOnly: true,
    );
    final fresh = existing == null
        ? Conversation(
            title: cast.length <= 3 ? title : '$title…',
            mode: ConversationMode.ensemble,
            characterId: cast.first.id,
            participantIds: [for (final c in cast) c.id],
            worldInfoIds: ids,
            venue: place,
            authorNote: authorNote,
            nextSpeakerIndex: 0,
            messages: [systemIntro],
            activeChildren: {kRootKey: systemIntro.id},
          )
        : existing.copyWith(
            title: cast.length <= 3 ? title : '$title…',
            characterId: cast.first.id,
            participantIds: [for (final c in cast) c.id],
            worldInfoIds: ids,
            venue: place,
            authorNote: authorNote,
            nextSpeakerIndex: 0,
            messages: [systemIntro],
            activeChildren: {kRootKey: systemIntro.id},
          );
    if (existing == null) {
      _set(
        _s.copyWith(
          conversations: [fresh, ..._s.conversations],
          currentId: fresh.id,
          error: null,
        ),
      );
    } else {
      _set(
        _s.copyWith(
          conversations: [
            for (final c in _s.conversations)
              if (c.id == fresh.id) fresh else c,
          ],
          currentId: fresh.id,
          error: null,
        ),
      );
    }
    _persistence.persistSoon(_persistence.persist());
  }

  /// Update story-session metadata on the current (or [conversationId]) chat.
  void updateStoryMeta({
    String? conversationId,
    String? outline,
    String? authorNote,
    List<String>? worldInfoIds,
    int? plotCursor,
    String? venue,
    List<String>? participantIds,
    int? nextSpeakerIndex,
    int? targetTotalChars,
  }) {
    final id = conversationId ?? _s.currentId;
    if (id == null) return;
    final idx = _s.conversations.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    final convo = _s.conversations[idx];
    if (!convo.isStoryLike) return;

    final beatsLen = parseOutlineBeats(outline ?? convo.outline).length;
    final nextCursor = plotCursor == null
        ? null
        : (beatsLen == 0
              ? plotCursor.clamp(0, 9999)
              : plotCursor.clamp(0, beatsLen));

    final cast = participantIds ?? convo.participantIds;
    final nextIdx = nextSpeakerIndex == null
        ? null
        : (cast.isEmpty ? 0 : nextSpeakerIndex.clamp(0, cast.length - 1));

    final nextTarget = targetTotalChars == null
        ? null
        : (targetTotalChars < 0 ? 0 : targetTotalChars);

    final updated = convo.copyWith(
      outline: outline,
      authorNote: authorNote,
      worldInfoIds: worldInfoIds,
      plotCursor: nextCursor,
      venue: venue,
      participantIds: participantIds,
      nextSpeakerIndex: nextIdx,
      targetTotalChars: nextTarget,
    );
    _set(_s.copyWith(conversations: _replace(updated)));
    _persistence.persistSoon(
      _persistence.enqueueWrite(
        () =>
            ref.read(conversationRepositoryProvider).saveConversation(updated),
      ),
    );
  }

  /// Nudge plot cursor by [delta] on the current story conversation.
  void adjustPlotCursor(int delta) {
    final convo = _s.current;
    if (convo == null || !convo.isStory) return;
    final beats = convo.outlineBeats;
    final max = beats.isEmpty
        ? convo.plotCursor + delta.abs() + 1
        : beats.length;
    final next = (convo.plotCursor + delta).clamp(0, max);
    updateStoryMeta(plotCursor: next);
  }

  /// Write the next unwritten outline beat as one scene.
  Future<void> advancePlot() =>
      _runStorySceneTurn(StoryGenerationIntent.nextScene);

  /// Continue the most recently written scene without moving the outline.
  Future<void> continueCurrentScene() =>
      _runStorySceneTurn(StoryGenerationIntent.continueScene);

  Future<void> _runStorySceneTurn(StoryGenerationIntent intent) async {
    if (_s.isStreaming || _starting) return;
    final convo = _s.current;
    if (convo == null || !convo.isStory) return;
    if (intent != StoryGenerationIntent.nextScene &&
        intent != StoryGenerationIntent.continueScene) {
      return;
    }

    _starting = true;
    _cancelStart = false;
    try {
      final settings = await _readySettings();
      if (settings == null || _cancelStart) return;
      final config = _configFor(settings);

      final parentId = convo.activePath.isEmpty
          ? null
          : convo.activePath.last.id;
      // A failed first attempt leaves an empty assistant placeholder on the
      // path; until a director reply actually landed, keep cueing 开始第一场.
      final firstSectionPending =
          convo.plotCursor == 0 &&
          !convo.activePath.any(
            (m) =>
                m.role == MessageRole.assistant && m.content.trim().isNotEmpty,
          );
      final beats = convo.outlineBeats;
      final promptCursor =
          intent == StoryGenerationIntent.continueScene &&
              !firstSectionPending &&
              convo.plotCursor > 0
          ? convo.plotCursor - 1
          : convo.plotCursor;
      final beatIndex = promptCursor.clamp(
        0,
        beats.isEmpty ? 0 : beats.length - 1,
      );
      final beatLine = beats.isEmpty
          ? ''
          : '\n当前节拍 ${beatIndex + 1}/${beats.length}：${beats[beatIndex]}';
      final directorCue = switch (intent) {
        StoryGenerationIntent.continueScene =>
          '（导演：续写当前场）$beatLine\n从上一段停顿处继续，保持场景连续。',
        _ when firstSectionPending => '（导演：开始第一场）$beatLine\n围绕当前目标写一场完整的戏。',
        _ => '（导演：写下一场）$beatLine\n围绕当前目标写一场完整的戏。',
      };
      final userMsg = ChatMessage(
        role: MessageRole.user,
        content: convo.localCast.isNotEmpty ? directorCue : '（推进情节）$beatLine',
        parentId: parentId,
      );
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: config.model,
        parentId: userMsg.id,
      );
      final working = convo.copyWith(
        messages: [...convo.messages, userMsg, assistantMsg],
        activeChildren: {
          ...convo.activeChildren,
          parentId ?? kRootKey: userMsg.id,
          userMsg.id: assistantMsg.id,
        },
      );

      if (_cancelStart) return;

      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: settings,
        searchQuery: '',
        thinking: _s.deepThink,
        advancePlot: true,
        promptPlotCursor: promptCursor,
        commitPlotAdvance: intent.advancesOutline,
        storyIntent: intent,
      );
    } finally {
      _finishStarting();
    }
  }

  /// User bubbles that mean "advance the outline", including director cues.
  static bool isPlotAdvanceUserContent(String content) {
    return StoryGenerationIntentResolver.fromUserText(content) ==
        StoryGenerationIntent.nextScene;
  }

  /// One AI line from the next cast member (round-robin).
  Future<void> ensembleNextTurn({
    String? forceCharacterId,

    /// Explicit target conversation (auto-play pins its origin so the loop
    /// keeps writing there even after the user switches conversations).
    String? conversationId,
  }) async {
    if (_s.isStreaming || _starting) return;
    final convo = conversationId == null
        ? _s.current
        : _s.conversations.where((c) => c.id == conversationId).firstOrNull;
    if (convo == null || !convo.isEnsemble) return;
    final castIds = convo.castIds;
    if (castIds.length < 2) {
      _set(_s.copyWith(error: '角色大乱斗需要至少 2 名角色。'));
      return;
    }

    var index = forceCharacterId != null
        ? castIds.indexOf(forceCharacterId)
        : convo.nextSpeakerIndex % castIds.length;
    if (index < 0) index = 0;
    final speakerId = castIds[index];
    final card = await ref.read(characterRepositoryProvider).getById(speakerId);
    if (card == null) {
      _set(_s.copyWith(error: '找不到角色卡，请检查参与名单。'));
      return;
    }

    _starting = true;
    _cancelStart = false;
    try {
      final settings = await _readySettings();
      if (settings == null || _cancelStart) return;
      final config = _configFor(settings);

      final parentId = convo.activePath.isEmpty
          ? null
          : convo.activePath.last.id;
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: config.model,
        parentId: parentId,
        speakerId: card.id,
        speakerName: card.name,
      );
      final nextIndex = (index + 1) % castIds.length;
      final working = convo.copyWith(
        messages: [...convo.messages, assistantMsg],
        activeChildren: {
          ...convo.activeChildren,
          parentId ?? kRootKey: assistantMsg.id,
        },
        nextSpeakerIndex: nextIndex,
      );

      if (_cancelStart) return;

      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: settings,
        searchQuery: '',
        thinking: _s.deepThink,
        ensembleSpeaker: card,
      );
    } finally {
      _finishStarting();
    }
  }

  /// Auto-run [rounds] ensemble turns (or until stop) on the conversation that
  /// started the run. Reading [_s.current] each round instead would retarget
  /// the loop whenever the user switches to another ensemble conversation.
  Future<void> ensembleAutoPlay({int rounds = 6}) async {
    final target = _s.current;
    if (target == null || !target.isEnsemble) return;
    final targetId = target.id;
    final n = rounds.clamp(1, 20);
    for (var i = 0; i < n; i++) {
      if (_s.isStreaming || _starting) return;
      await ensembleNextTurn(conversationId: targetId);
      // Allow UI to settle between turns.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final after = _s.conversations.where((c) => c.id == targetId).firstOrNull;
      if (_cancelStart || after == null || !after.isEnsemble) return;
      // Stop on errors that belong to the target conversation; a banner parked
      // on another conversation must not end this run.
      final err = _s.error;
      final errOnTarget =
          _s.errorConvoId == null || _s.errorConvoId == targetId;
      if (err != null && err.isNotEmpty && errOnTarget) return;
    }
  }

  /// Toggle the "深度思考" switch shown next to the composer.
  void toggleDeepThink() {
    _set(_s.copyWith(deepThink: !_s.deepThink));
  }

  void setReasoningEffort(ReasoningEffort effort) {
    if (_s.reasoningEffort == effort) return;
    _set(_s.copyWith(reasoningEffort: effort));
    unawaited(
      ref.read(settingsControllerProvider.notifier).setReasoningEffort(effort),
    );
  }

  /// Cycle the "联网" switch shown next to the composer: 关 → 自动 → 强制 → 关.
  void toggleSearch() {
    final next = _s.searchMode.next;
    _set(_s.copyWith(searchMode: next));
    unawaited(
      ref.read(settingsControllerProvider.notifier).setSearchMode(next),
    );
  }

  /// Apply composer defaults after settings load or JSON import.
  void applyComposerPrefs({
    required SearchMode searchMode,
    required ImageGenMode imageGenMode,
    required ReasoningEffort reasoningEffort,
  }) {
    if (_s.searchMode == searchMode &&
        _s.imageGenMode == imageGenMode &&
        _s.reasoningEffort == reasoningEffort) {
      return;
    }
    _set(
      _s.copyWith(
        searchMode: searchMode,
        imageGenMode: imageGenMode,
        reasoningEffort: reasoningEffort,
      ),
    );
  }

  /// Cycle dialogue "配图": 关 → 自动 → 强制 → 关.
  void toggleImageGenMode() {
    final next = _s.imageGenMode.next;
    _set(_s.copyWith(imageGenMode: next));
    unawaited(
      ref.read(settingsControllerProvider.notifier).setImageGenMode(next),
    );
  }

  void setWorkMode(bool enabled) {
    final current = _s.current;
    if (current == null || current.workMode == enabled) return;
    final updated = current.copyWith(workMode: enabled);
    _set(_s.copyWith(conversations: _replace(updated)));
    _persistence.persistSoon(
      _persistence.enqueueWrite(
        () =>
            ref.read(conversationRepositoryProvider).saveConversation(updated),
      ),
    );
  }

  void setCustomMcpServerIds(List<String> ids) {
    final current = _s.current;
    if (current == null) return;
    final nextIds = [
      for (final id in ids)
        if (id.trim().isNotEmpty) id.trim(),
    ];
    if (_sameStringList(current.customMcpServerIds, nextIds)) return;
    final updated = current.copyWith(customMcpServerIds: nextIds);
    _set(_s.copyWith(conversations: _replace(updated)));
    _persistence.persistSoon(
      _persistence.enqueueWrite(
        () =>
            ref.read(conversationRepositoryProvider).saveConversation(updated),
      ),
    );
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void renameConversation(String id, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    Conversation? renamed;
    final updated = [
      for (final c in _s.conversations)
        if (c.id == id) (renamed = c.copyWith(title: trimmed)) else c,
    ];
    _set(_s.copyWith(conversations: updated));
    // Save the renamed conversation specifically (it may not be the active one).
    final r = renamed;
    if (r != null) {
      _persistence.persistSoon(
        _persistence.enqueueWrite(
          () => ref.read(conversationRepositoryProvider).saveConversation(r),
        ),
      );
    }
  }

  Future<void> deleteConversation(String id) async {
    // Deleting the conversation that is currently streaming: abort the stream
    // first, WITHOUT persisting it (a late save would resurrect the row).
    if (_s.streamingConvoId == id) stop(persist: false);

    // Also tombstone it against a generation that is still preflighting
    // (awaiting settings): streamingConvoId is not set yet, so only this
    // record can stop _generate from re-inserting the stale snapshot.
    _rememberDeletedConversation(id);

    // Remove it from memory before awaiting the database operation. The stream
    // teardown may resume as soon as stop() completes; persistById then sees
    // no matching conversation and cannot enqueue a save behind this delete.
    final beforeDeletion = _s;
    final deletedIndex = beforeDeletion.conversations.indexWhere(
      (c) => c.id == id,
    );
    if (deletedIndex < 0) return;
    final deletedConversation = beforeDeletion.conversations[deletedIndex];
    final remaining = beforeDeletion.conversations
        .where((c) => c.id != id)
        .toList();
    final createsFreshConversation = remaining.isEmpty;
    final nextConversations = createsFreshConversation
        ? <Conversation>[Conversation()]
        : remaining;
    final nextCurrent = beforeDeletion.currentId == id
        ? nextConversations.first.id
        : beforeDeletion.currentId;
    // Only the deleted conversation's scoped error is cleared; a banner parked
    // on another conversation (see selectConversation) must survive.
    final clearsError = beforeDeletion.errorConvoId == id;
    _set(
      beforeDeletion.copyWith(
        conversations: nextConversations,
        currentId: nextCurrent,
        contextReports: {...beforeDeletion.contextReports}..remove(id),
        error: clearsError ? null : beforeDeletion.error,
        errorConvoId: clearsError ? null : beforeDeletion.errorConvoId,
        retryOperation: clearsError ? null : beforeDeletion.retryOperation,
      ),
    );

    try {
      await _persistence.deletePersistedConversation(id);
    } catch (e) {
      // The row is still alive; drop the tombstone so a later send into this
      // restored conversation is not wrongly abandoned.
      _deletedWhileStartingIds.remove(id);
      // Keep the archive visible if deleting its row failed, but do not restore
      // the entire old state: the user may have created or edited another
      // conversation while this awaited database write was in flight.
      if (ref.mounted) {
        final current = _s;
        final restored = current.conversations.any((c) => c.id == id)
            ? current.conversations
            : [
                ...current.conversations.take(deletedIndex),
                deletedConversation,
                ...current.conversations.skip(deletedIndex),
              ];
        _set(
          current.copyWith(
            conversations: restored,
            error: '本地删除失败：$e',
            errorConvoId: id,
          ),
        );
      }
      return;
    }

    if (createsFreshConversation) {
      _persistence.persistSoon(_persistence.persist());
    }
  }

  void _rememberDeletedConversation(String id) {
    _deletedWhileStartingIds.add(id);
    // Bounded: only the in-flight preflight window consults it, so a rolling
    // window of recent deletions is more than enough.
    while (_deletedWhileStartingIds.length > 128) {
      _deletedWhileStartingIds.remove(_deletedWhileStartingIds.first);
    }
  }
}
