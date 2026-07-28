import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import '../core/providers.dart';
import '../data/research/research_prefs.dart';
import '../data/research/ssh_profile.dart';
import '../domain/research/command_risk.dart';
import '../domain/research/research_copilot_service.dart';
import '../domain/research/research_ssh_client.dart';
import '../domain/research/terminal_input_guard.dart';
import '../domain/research/terminal_transcript_buffer.dart';
import '../domain/research/tmux_service.dart';
import 'settings_controller.dart';

enum ResearchConnectionStatus { disconnected, connecting, connected, error }

class ResearchTerminalState {
  const ResearchTerminalState({
    this.profiles = const [],
    this.activeProfileId,
    this.status = ResearchConnectionStatus.disconnected,
    this.statusMessage = '',
    this.connectionGeneration = 0,
    this.tmuxSessions = const [],
    this.tmuxError,
    this.currentTmuxName,
    this.aiContextLines = ResearchPrefs.defaultAiContextLines,
    this.blockCtrlC = ResearchPrefs.defaultBlockCtrlC,
    this.proposal,
    this.analyzing = false,
    this.latencyMs,
    this.cols = 80,
    this.rows = 24,
    this.interruptBlockedFlash = false,
    this.ctrlLatched = false,
  });

  final List<SshProfile> profiles;
  final String? activeProfileId;
  final ResearchConnectionStatus status;
  final String statusMessage;

  /// Bumped on each connect/disconnect so old approvals die.
  final int connectionGeneration;
  final List<TmuxSessionInfo> tmuxSessions;
  final String? tmuxError;
  final String? currentTmuxName;
  final int aiContextLines;

  /// When true, interrupt chars (Ctrl+C / Ctrl+\) never reach the PTY.
  final bool blockCtrlC;
  final CommandProposal? proposal;
  final bool analyzing;
  final int? latencyMs;
  final int cols;
  final int rows;

  /// Brief UI hint after an intercepted interrupt char.
  final bool interruptBlockedFlash;

  /// Ctrl held for the next keystroke — a soft keyboard has no Ctrl key, so the
  /// modifier is latched here and applied in [ResearchTerminalController
  /// .writeUserInput], which every input path goes through.
  final bool ctrlLatched;

  SshProfile? get activeProfile {
    if (profiles.isEmpty) return null;
    if (activeProfileId == null) return profiles.first;
    for (final profile in profiles) {
      if (profile.id == activeProfileId) return profile;
    }
    return null;
  }

  bool get isConnected => status == ResearchConnectionStatus.connected;

  ResearchTerminalState copyWith({
    List<SshProfile>? profiles,
    Object? activeProfileId = _s,
    ResearchConnectionStatus? status,
    String? statusMessage,
    int? connectionGeneration,
    List<TmuxSessionInfo>? tmuxSessions,
    Object? tmuxError = _s,
    Object? currentTmuxName = _s,
    int? aiContextLines,
    bool? blockCtrlC,
    Object? proposal = _s,
    bool? analyzing,
    Object? latencyMs = _s,
    int? cols,
    int? rows,
    bool? interruptBlockedFlash,
    bool? ctrlLatched,
  }) => ResearchTerminalState(
    profiles: profiles ?? this.profiles,
    activeProfileId: identical(activeProfileId, _s)
        ? this.activeProfileId
        : activeProfileId as String?,
    status: status ?? this.status,
    statusMessage: statusMessage ?? this.statusMessage,
    connectionGeneration: connectionGeneration ?? this.connectionGeneration,
    tmuxSessions: tmuxSessions ?? this.tmuxSessions,
    tmuxError: identical(tmuxError, _s) ? this.tmuxError : tmuxError as String?,
    currentTmuxName: identical(currentTmuxName, _s)
        ? this.currentTmuxName
        : currentTmuxName as String?,
    aiContextLines: aiContextLines ?? this.aiContextLines,
    blockCtrlC: blockCtrlC ?? this.blockCtrlC,
    proposal: identical(proposal, _s)
        ? this.proposal
        : proposal as CommandProposal?,
    analyzing: analyzing ?? this.analyzing,
    latencyMs: identical(latencyMs, _s) ? this.latencyMs : latencyMs as int?,
    cols: cols ?? this.cols,
    rows: rows ?? this.rows,
    interruptBlockedFlash: interruptBlockedFlash ?? this.interruptBlockedFlash,
    ctrlLatched: ctrlLatched ?? this.ctrlLatched,
  );

  static const _s = Object();
}

final researchTerminalProvider =
    NotifierProvider<ResearchTerminalController, ResearchTerminalState>(
      ResearchTerminalController.new,
    );

class ResearchTerminalController extends Notifier<ResearchTerminalState> {
  ResearchSshClient? _client;
  final transcript = TerminalTranscriptBuffer();
  final terminal = Terminal(maxLines: 10000);
  final _tmux = const TmuxService();
  final _uuid = const Uuid();
  final List<StreamSubscription<dynamic>> _subs = [];
  ResearchSshClientFactory _clientFactory = createResearchSshClient;
  var _disposed = false;
  var _connectionRequest = 0;

  /// For tests.
  @visibleForTesting
  void debugSetClientFactory(ResearchSshClientFactory factory) {
    _clientFactory = factory;
  }

  @override
  ResearchTerminalState build() {
    ref.onDispose(() {
      _disposed = true;
      unawaited(releaseAll());
    });
    final prefs = ResearchPrefs(ref.read(sharedPrefsProvider));
    return ResearchTerminalState(
      profiles: prefs.loadProfiles(),
      aiContextLines: prefs.loadAiContextLines(),
      blockCtrlC: prefs.loadBlockCtrlC(),
    );
  }

  ResearchPrefs get _prefs => ResearchPrefs(ref.read(sharedPrefsProvider));

  Future<void> reloadProfiles() async {
    state = state.copyWith(profiles: _prefs.loadProfiles());
  }

  Future<void> saveProfile(
    SshProfile profile, {
    String? password,
    String? privateKeyPem,
    String? passphrase,
  }) async {
    final secure = ref.read(secureStorageProvider);
    final list = [...state.profiles];
    final idx = list.indexWhere((p) => p.id == profile.id);
    final existing = idx >= 0 ? list[idx] : null;
    final activeBeforeSave = state.activeProfileId;
    final keepConnectedProfileActive =
        activeBeforeSave != null &&
        profile.id != activeBeforeSave &&
        (state.status == ResearchConnectionStatus.connecting ||
            state.isConnected);
    final editsActiveConnection =
        existing != null &&
        profile.id == state.activeProfileId &&
        (state.status == ResearchConnectionStatus.connecting ||
            state.isConnected) &&
        _connectionTargetChanged(existing, profile);
    if (editsActiveConnection) {
      // Never let the displayed/approved profile drift away from the actual
      // SSH transport. A changed endpoint must reconnect and mint a new
      // approval generation before it can receive commands.
      await disconnect();
    }
    if (idx >= 0) {
      list[idx] = profile;
    } else {
      list.add(profile);
    }
    await _prefs.saveProfiles(list);
    if (password != null) {
      if (password.isEmpty) {
        await secure.delete(key: ResearchSecureKeys.password(profile.id));
      } else {
        await secure.write(
          key: ResearchSecureKeys.password(profile.id),
          value: password,
        );
      }
    }
    if (privateKeyPem != null) {
      if (privateKeyPem.isEmpty) {
        await secure.delete(key: ResearchSecureKeys.privateKey(profile.id));
      } else {
        await secure.write(
          key: ResearchSecureKeys.privateKey(profile.id),
          value: privateKeyPem,
        );
      }
    }
    if (passphrase != null) {
      if (passphrase.isEmpty) {
        await secure.delete(key: ResearchSecureKeys.passphrase(profile.id));
      } else {
        await secure.write(
          key: ResearchSecureKeys.passphrase(profile.id),
          value: passphrase,
        );
      }
    }
    state = state.copyWith(
      profiles: list,
      activeProfileId: keepConnectedProfileActive
          ? activeBeforeSave
          : profile.id,
    );
  }

  Future<void> deleteProfile(String id) async {
    if (state.activeProfileId == id &&
        (state.status == ResearchConnectionStatus.connecting ||
            state.isConnected ||
            _client != null)) {
      await disconnect();
    }
    final secure = ref.read(secureStorageProvider);
    final list = state.profiles.where((p) => p.id != id).toList();
    await _prefs.saveProfiles(list);
    await secure.delete(key: ResearchSecureKeys.password(id));
    await secure.delete(key: ResearchSecureKeys.privateKey(id));
    await secure.delete(key: ResearchSecureKeys.passphrase(id));
    state = state.copyWith(
      profiles: list,
      activeProfileId: state.activeProfileId == id
          ? null
          : state.activeProfileId,
    );
  }

  Future<void> setAiContextLines(int lines) async {
    await _prefs.saveAiContextLines(lines);
    state = state.copyWith(aiContextLines: lines);
  }

  Future<void> setBlockCtrlC(bool value) async {
    await _prefs.saveBlockCtrlC(value);
    state = state.copyWith(blockCtrlC: value, interruptBlockedFlash: false);
  }

  String previewForAi() => transcript.recentForAi(state.aiContextLines);

  /// Latches Ctrl for the next keystroke (soft keyboards have no Ctrl key).
  void setCtrlLatched(bool value) {
    if (state.ctrlLatched != value) {
      state = state.copyWith(ctrlLatched: value);
    }
  }

  /// Writes user keystrokes / shortcuts to the PTY, applying a pending Ctrl
  /// latch and optionally stripping interrupt chars. Returns true if an
  /// interrupt char was blocked.
  bool writeUserInput(String data, {bool force = false}) {
    final client = _client;
    if (client == null || !client.isConnected) return false;
    var payload = data;
    if (!force && state.ctrlLatched && data.isNotEmpty) {
      payload = TerminalInputGuard.applyCtrlLatch(data) ?? data;
      // A real Ctrl key releases after one keystroke; so does this.
      state = state.copyWith(ctrlLatched: false);
    }
    final result = TerminalInputGuard.filter(
      payload,
      blockInterrupt: force ? false : state.blockCtrlC,
    );
    if (result.blockedInterrupt) {
      state = state.copyWith(interruptBlockedFlash: true);
    }
    if (result.data.isNotEmpty) {
      client.write(utf8.encode(result.data));
    }
    return result.blockedInterrupt;
  }

  void clearInterruptBlockedFlash() {
    if (state.interruptBlockedFlash) {
      state = state.copyWith(interruptBlockedFlash: false);
    }
  }

  Future<void> connect(SshProfile profile) async {
    if (kIsWeb) {
      state = state.copyWith(
        status: ResearchConnectionStatus.error,
        statusMessage: '浏览器无法建立原生 SSH 连接',
      );
      return;
    }
    final request = ++_connectionRequest;
    await disconnect(bumpGeneration: true, invalidateConnectAttempts: false);
    if (!_isCurrentConnectRequest(request)) return;
    state = state.copyWith(
      status: ResearchConnectionStatus.connecting,
      statusMessage: '正在连接 ${profile.host}…',
      activeProfileId: profile.id,
      proposal: null,
      tmuxError: null,
    );

    final secure = ref.read(secureStorageProvider);
    final password = await secure.read(
      key: ResearchSecureKeys.password(profile.id),
    );
    final privateKey = await secure.read(
      key: ResearchSecureKeys.privateKey(profile.id),
    );
    final passphrase = await secure.read(
      key: ResearchSecureKeys.passphrase(profile.id),
    );
    if (!_isCurrentConnectRequest(request)) return;

    final client = _clientFactory();
    _client = client;
    final sw = Stopwatch()..start();

    bool stillThisClient() =>
        _isCurrentConnectRequest(request) && identical(_client, client);

    try {
      await client.connect(
        profile: profile,
        password: password,
        privateKeyPem: privateKey,
        passphrase: passphrase,
        cols: state.cols,
        rows: state.rows,
        onHostKeyTrust: (info) async {
          // UI layer should have set a handler via pending dialog; default deny
          // if no callback wired — controller stores last request for UI.
          final handler = _hostKeyTrustHandler;
          if (handler == null) return false;
          return handler(info);
        },
        onHostKeyMismatch: (info, prev) async {
          final handler = _hostKeyMismatchHandler;
          if (handler == null) return false;
          return handler(info, prev);
        },
      );
      if (!stillThisClient()) {
        await client.disconnect();
        return;
      }
      sw.stop();

      // Persist trusted fingerprint if newly accepted.
      final fp = client.lastHostKeyFingerprint;
      if (fp != null &&
          (profile.trustedHostKeyFingerprint == null ||
              profile.trustedHostKeyFingerprint != fp)) {
        final updated = profile.copyWith(
          trustedHostKeyFingerprint: fp,
          lastUsedAt: DateTime.now(),
        );
        await saveProfile(updated);
      } else {
        await saveProfile(profile.copyWith(lastUsedAt: DateTime.now()));
      }
      if (!stillThisClient()) {
        await client.disconnect();
        return;
      }

      terminal.buffer.clear();
      terminal.buffer.setCursor(0, 0);
      transcript.clear();

      _subs.add(
        client.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(
          (text) {
            if (!identical(_client, client)) return;
            terminal.write(text);
            transcript.append(text);
          },
        ),
      );
      _subs.add(
        client.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(
          (text) {
            if (!identical(_client, client)) return;
            terminal.write(text);
            transcript.append(text);
          },
        ),
      );
      // Remote shell closed — update UI (do not use asStream on a completed
      // Future; that would fire synchronously and re-enter disconnect).
      unawaited(
        client.done.then((_) async {
          if (!identical(_client, client) || _disposed) return;
          await disconnect(bumpGeneration: true);
          if (_disposed || !ref.mounted) return;
          if (state.status == ResearchConnectionStatus.disconnected &&
              state.statusMessage.isEmpty) {
            state = state.copyWith(statusMessage: '远端 shell 已关闭');
          }
        }),
      );

      terminal.onOutput = (data) {
        // Always go through the guard so hardware Ctrl+C is filtered too.
        writeUserInput(data);
      };
      terminal.onResize = (w, h, pw, ph) {
        if (_disposed || !ref.mounted) return;
        if (!identical(_client, client)) return;
        // Ignore degenerate sizes during IME open/close animation — resizing
        // PTY to 0×N can blank the canvas and leave a white shell body.
        if (w < 2 || h < 2) return;
        client.resize(cols: w, rows: h);
        if (state.cols == w && state.rows == h) return;
        // xterm fires this from RenderTerminal.performLayout, i.e. mid-frame.
        // Assigning state there rebuilds listeners during layout, which
        // Riverpod asserts on. The size is only read when opening a shell, so
        // publishing it after the frame drains costs nothing.
        unawaited(
          Future.microtask(() {
            if (_disposed || !ref.mounted) return;
            if (!identical(_client, client)) return;
            state = state.copyWith(cols: w, rows: h);
          }),
        );
      };

      state = state.copyWith(
        status: ResearchConnectionStatus.connected,
        statusMessage: '已连接',
        connectionGeneration: state.connectionGeneration + 1,
        latencyMs: sw.elapsedMilliseconds,
        proposal: null,
        analyzing: false,
      );
      unawaited(refreshTmux());
    } catch (e) {
      if (identical(_client, client)) {
        await client.disconnect();
        _client = null;
      } else {
        await client.disconnect();
      }
      if (!_isCurrentConnectRequest(request)) return;
      // Another connect owns _client now — do not clobber its state.
      if (_client != null && !identical(_client, client)) return;
      state = state.copyWith(
        status: ResearchConnectionStatus.error,
        statusMessage: _safeError(e),
        connectionGeneration: state.connectionGeneration + 1,
        analyzing: false,
        proposal: null,
      );
    }
  }

  HostKeyTrustHandler? _hostKeyTrustHandler;
  HostKeyMismatchHandler? _hostKeyMismatchHandler;

  void setHostKeyHandlers({
    HostKeyTrustHandler? onTrust,
    HostKeyMismatchHandler? onMismatch,
  }) {
    _hostKeyTrustHandler = onTrust;
    _hostKeyMismatchHandler = onMismatch;
  }

  /// Unbinds handlers a now-disposed page had registered.
  ///
  /// The controller outlives the page, so a stale handler would keep pushing
  /// dialogs onto a dead [BuildContext]. Clearing only when the stored handler
  /// is still the caller's own matters because a new page may already have
  /// bound its own while the old one was tearing down — dropping *that* would
  /// silently deny every later host-key prompt.
  void clearHostKeyHandlers({
    HostKeyTrustHandler? onTrust,
    HostKeyMismatchHandler? onMismatch,
  }) {
    if (onTrust != null && _hostKeyTrustHandler == onTrust) {
      _hostKeyTrustHandler = null;
    }
    if (onMismatch != null && _hostKeyMismatchHandler == onMismatch) {
      _hostKeyMismatchHandler = null;
    }
  }

  Future<void> disconnect({
    bool bumpGeneration = true,
    bool invalidateConnectAttempts = true,
  }) async {
    if (invalidateConnectAttempts) {
      _connectionRequest++;
    }
    // Copy first — done/stdout handlers must not mutate while we cancel.
    final pending = List<StreamSubscription<dynamic>>.of(_subs);
    _subs.clear();
    for (final s in pending) {
      await s.cancel();
    }
    terminal.onOutput = null;
    terminal.onResize = null;
    final client = _client;
    _client = null;
    await client?.disconnect();
    // Provider may already be tearing down (research mode off / container dispose).
    if (_disposed || !ref.mounted) return;
    state = state.copyWith(
      status: ResearchConnectionStatus.disconnected,
      statusMessage: '',
      connectionGeneration: bumpGeneration
          ? state.connectionGeneration + 1
          : state.connectionGeneration,
      proposal: null,
      analyzing: false,
      tmuxSessions: const [],
      currentTmuxName: null,
      latencyMs: null,
    );
  }

  /// Full teardown when research mode is turned off.
  Future<void> releaseAll() async {
    await disconnect(bumpGeneration: true);
    transcript.clear();
    try {
      terminal.buffer.clear();
    } catch (_) {}
  }

  /// Test helper: inject a proposal without calling the LLM.
  @visibleForTesting
  void debugSetProposal(CommandProposal? proposal) {
    state = state.copyWith(proposal: proposal);
  }

  Future<void> refreshTmux() async {
    final client = _client;
    if (client == null || !client.isConnected) {
      state = state.copyWith(tmuxSessions: const [], tmuxError: 'SSH 未连接');
      return;
    }
    final generation = state.connectionGeneration;
    try {
      final sessions = await _tmux.listSessions(client);
      if (!_ownsConnection(client, generation)) return;
      state = state.copyWith(
        tmuxSessions: sessions,
        tmuxError: null,
        currentTmuxName: _reconcileCurrentTmux(sessions),
      );
    } on TmuxNotInstalledException {
      if (!_ownsConnection(client, generation)) return;
      state = state.copyWith(
        tmuxSessions: const [],
        tmuxError: '远端未安装 tmux',
        currentTmuxName: null,
      );
    } catch (e) {
      if (!_ownsConnection(client, generation)) return;
      state = state.copyWith(tmuxError: _safeError(e));
    }
  }

  /// The session we still believe we are attached to, per the server's view.
  ///
  /// The user can leave tmux behind our back (typing `exit`, or `C-b d` on a
  /// hardware keyboard), after which the banner would keep claiming an
  /// attachment that no longer exists and `switchTmuxSession` would send
  /// `switch-client` into a bare shell. Anything the server no longer reports
  /// as attached is dropped.
  ///
  /// `session_attached` counts *all* clients, so a session another terminal
  /// holds open still reads as attached. That direction is the safe one: we
  /// keep a possibly-stale name rather than dropping a live one.
  String? _reconcileCurrentTmux(List<TmuxSessionInfo> sessions) {
    final current = state.currentTmuxName;
    if (current == null) return null;
    for (final s in sessions) {
      if (s.name == current) return s.attached > 0 ? current : null;
    }
    return null;
  }

  Future<void> createTmuxSession(String name) async {
    final client = _client;
    if (client == null || !client.isConnected) return;
    final generation = state.connectionGeneration;
    try {
      await _tmux.createSession(client, name);
      if (!_ownsConnection(client, generation)) return;
      // List before attaching: afterwards the attach may not have landed yet,
      // and reconciliation would read attached=0 and drop the name we just set.
      await refreshTmux();
      if (!_ownsConnection(client, generation)) return;
      // Creating from inside tmux must switch, not nest an attach.
      await _tmux.switchOrAttachInShell(
        client,
        name,
        currentlyInTmux: state.currentTmuxName != null,
      );
      if (!_ownsConnection(client, generation)) return;
      state = state.copyWith(currentTmuxName: name, tmuxError: null);
    } catch (e) {
      if (!_ownsConnection(client, generation)) return;
      state = state.copyWith(tmuxError: _safeError(e));
    }
  }

  void attachTmuxSession(String name) {
    final client = _client;
    if (client == null || !client.isConnected) return;
    _tmux.attachInShell(client, name);
    state = state.copyWith(currentTmuxName: name);
  }

  /// Switch to [name] directly: switch-client when already in tmux, else attach.
  Future<void> switchTmuxSession(String name) async {
    final client = _client;
    if (client == null || !client.isConnected) return;
    final target = name.trim();
    if (target.isEmpty) return;
    if (state.currentTmuxName == target) return;
    final generation = state.connectionGeneration;
    final inTmux = state.currentTmuxName != null;
    try {
      await _tmux.switchOrAttachInShell(
        client,
        target,
        currentlyInTmux: inTmux,
      );
      if (!_ownsConnection(client, generation)) return;
      state = state.copyWith(currentTmuxName: target);
    } catch (e) {
      if (!_ownsConnection(client, generation)) return;
      state = state.copyWith(tmuxError: _safeError(e));
    }
  }

  /// Leave the attached tmux client without stopping remote jobs.
  Future<void> detachTmuxSession() async {
    final client = _client;
    if (client == null || !client.isConnected) return;
    final name = state.currentTmuxName;
    // Not attached to anything: the old prefix-key write would have dropped
    // `C-b d` straight into the user's command line.
    if (name == null) return;
    final generation = state.connectionGeneration;
    try {
      await _tmux.detachSession(client, name);
      if (!_ownsConnection(client, generation)) return;
      state = state.copyWith(currentTmuxName: null, tmuxError: null);
    } catch (e) {
      if (!_ownsConnection(client, generation)) return;
      state = state.copyWith(tmuxError: _safeError(e));
    }
  }

  void sendShortcut(String sequence, {bool force = false}) {
    writeUserInput(sequence, force: force);
  }

  /// Explicit interrupt after user confirms — bypasses [blockCtrlC].
  void sendCtrlCForced() {
    writeUserInput(TerminalInputGuard.ctrlC, force: true);
  }

  /// [userGoal]: natural-language intent (e.g. "看一下 GPU 占用").
  /// Either [userGoal] or non-empty transcript is required.
  Future<void> analyzeWithAi({String? userGoal}) async {
    final settings = ref.read(settingsControllerProvider).value;
    if (settings == null || !settings.config.isReady) {
      state = state.copyWith(
        proposal: CommandProposal(
          id: _uuid.v4(),
          diagnosis: '请先在设置中配置可用的对话 API。',
          command: '',
          risk: CommandRisk.blocked,
          evidence: const [],
          impacts: const [],
          nonImpacts: const [],
          parseOk: false,
        ),
      );
      return;
    }
    final goal = userGoal?.trim() ?? '';
    final preview = previewForAi();
    if (goal.isEmpty && preview.trim().isEmpty) {
      state = state.copyWith(
        proposal: CommandProposal(
          id: _uuid.v4(),
          diagnosis: '请输入你想做什么，或先在终端产生一些输出再分析。',
          command: '',
          risk: CommandRisk.blocked,
          evidence: const [],
          impacts: const [],
          nonImpacts: const [],
          parseOk: false,
        ),
      );
      return;
    }
    final analyzeGen = state.connectionGeneration;
    final analyzeHost = state.activeProfileId;
    state = state.copyWith(analyzing: true, proposal: null);
    final copilot = ResearchCopilotService(ref.read(llmProvider));
    try {
      final proposal = await copilot.analyze(
        config: settings.config,
        transcriptPreview: preview,
        userGoal: goal.isEmpty ? null : goal,
        proposalId: _uuid.v4(),
      );
      if (_disposed || !ref.mounted) return;
      // Drop stale results after host switch / reconnect / disconnect.
      if (state.connectionGeneration != analyzeGen ||
          state.activeProfileId != analyzeHost) {
        if (state.analyzing) {
          state = state.copyWith(analyzing: false);
        }
        return;
      }
      state = state.copyWith(analyzing: false, proposal: proposal);
    } catch (e) {
      if (_disposed || !ref.mounted) return;
      if (state.connectionGeneration != analyzeGen ||
          state.activeProfileId != analyzeHost) {
        if (state.analyzing) {
          state = state.copyWith(analyzing: false);
        }
        return;
      }
      state = state.copyWith(
        analyzing: false,
        proposal: CommandProposal(
          id: _uuid.v4(),
          diagnosis: '分析失败：${_safeError(e)}',
          command: '',
          risk: CommandRisk.blocked,
          evidence: const [],
          impacts: const [],
          nonImpacts: const [],
          parseOk: false,
        ),
      );
    }
  }

  void clearProposal() {
    state = state.copyWith(proposal: null);
  }

  CommandProposal? editProposalCommand(String command) {
    final base = state.proposal;
    if (base == null) return null;
    final copilot = ResearchCopilotService(ref.read(llmProvider));
    final next = copilot.withEditedCommand(base, command);
    state = state.copyWith(proposal: next);
    return next;
  }

  /// Creates an [ApprovedCommand] only after UI final confirmation.
  ApprovedCommand? approveCurrentProposal({
    required String command,
    required String cwdHint,
  }) {
    final p = state.proposal;
    final hostId = state.activeProfileId;
    if (p == null || hostId == null || !p.canOfferExecute) return null;
    if (!state.isConnected) return null;
    final local = const CommandRiskClassifier().classify(command);
    final risk = CommandRisk.max(p.risk, local.risk);
    if (risk == CommandRisk.blocked) return null;
    return ApprovedCommand(
      proposalId: p.id,
      hostId: hostId,
      connectionGeneration: state.connectionGeneration,
      command: command,
      risk: risk,
      cwdHint: cwdHint,
    );
  }

  void executeApproved(ApprovedCommand approved) {
    final client = _client;
    final hostId = state.activeProfileId;
    if (client == null || hostId == null || !client.isConnected) {
      throw StateError('未连接，无法执行');
    }
    const ApprovedCommandExecutor().execute(
      writeToShell: client.write,
      approved: approved,
      activeHostId: hostId,
      activeConnectionGeneration: state.connectionGeneration,
    );
    // Invalidate reuse of the same proposal.
    state = state.copyWith(proposal: null);
  }

  static String _safeError(Object e) {
    final s = e.toString();
    // Strip anything that looks like a key or PEM.
    return TerminalTranscriptBuffer.redactSecrets(
      s.length > 200 ? '${s.substring(0, 200)}…' : s,
    );
  }

  bool _isCurrentConnectRequest(int request) =>
      !_disposed && ref.mounted && request == _connectionRequest;

  bool _ownsConnection(ResearchSshClient client, int generation) =>
      !_disposed &&
      ref.mounted &&
      identical(_client, client) &&
      client.isConnected &&
      state.connectionGeneration == generation;

  static bool _connectionTargetChanged(SshProfile a, SshProfile b) =>
      a.host != b.host ||
      a.port != b.port ||
      a.username != b.username ||
      a.authType != b.authType;
}
