import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/research/research_prefs.dart';
import 'package:expert_chat/data/research/ssh_profile.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/research/command_risk.dart';
import 'package:expert_chat/domain/research/research_copilot_service.dart';
import 'package:expert_chat/domain/research/research_ssh_client.dart';
import 'package:expert_chat/domain/research/shell_quoting.dart';
import 'package:expert_chat/domain/research/terminal_input_guard.dart';
import 'package:expert_chat/domain/research/terminal_transcript_buffer.dart';
import 'package:expert_chat/domain/research/tmux_service.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:expert_chat/state/research_terminal_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ScriptLlm implements LlmProvider {
  _ScriptLlm(this.reply);
  final String reply;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  }) async* {
    yield ChatChunk(contentDelta: reply);
  }
}

class _FakeSshClient implements ResearchSshClient {
  final _out = StreamController<List<int>>.broadcast();
  final _err = StreamController<List<int>>.broadcast();
  final writes = <String>[];
  final execCommands = <String>[];
  var connected = false;
  var cols = 80;
  var rows = 24;
  String execResult = '';
  Object? execError;
  Completer<String>? execCompleter;
  Completer<void>? connectCompleter;
  var disconnectCount = 0;
  Completer<void>? _done;

  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Future<void> get done => _done?.future ?? Future.value();
  @override
  bool get isConnected => connected;
  @override
  String? get lastHostKeyFingerprint => 'SHA256:fake';

  @override
  Future<void> connect({
    required SshProfile profile,
    required String? password,
    required String? privateKeyPem,
    required String? passphrase,
    required HostKeyTrustHandler onHostKeyTrust,
    required HostKeyMismatchHandler onHostKeyMismatch,
    int cols = 80,
    int rows = 24,
    Duration connectTimeout = const Duration(seconds: 15),
  }) async {
    final trusted = profile.trustedHostKeyFingerprint?.trim();
    const info = ResearchHostKeyInfo(
      fingerprintSha256: 'SHA256:fake',
      keyType: 'ssh-ed25519',
    );
    if (trusted == null || trusted.isEmpty) {
      final ok = await onHostKeyTrust(info);
      if (!ok) throw ResearchSshException('主机密钥验证失败或已取消');
    } else if (trusted != info.fingerprintSha256) {
      final ok = await onHostKeyMismatch(info, trusted);
      if (!ok) throw ResearchSshException('主机密钥验证失败或已取消');
    }
    final pendingConnect = connectCompleter;
    if (pendingConnect != null) await pendingConnect.future;
    connected = true;
    this.cols = cols;
    this.rows = rows;
    _done = Completer<void>();
  }

  @override
  void write(List<int> data) {
    writes.add(utf8.decode(data));
  }

  @override
  void resize({required int cols, required int rows}) {
    this.cols = cols;
    this.rows = rows;
  }

  @override
  Future<String> runExec(
    String command, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    execCommands.add(command);
    final error = execError;
    if (error != null) throw error;
    final pending = execCompleter;
    if (pending != null) return pending.future;
    return execResult;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    disconnectCount++;
    final d = _done;
    if (d != null && !d.isCompleted) d.complete();
  }

  void pushStdout(String text) {
    _out.add(utf8.encode(text));
  }

  void pushStdoutBytes(List<int> bytes) {
    _out.add(bytes);
  }
}

ProviderContainer _baseContainer({
  required SharedPreferences prefs,
  LlmProvider? llm,
}) {
  return ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      if (llm != null) llmProvider.overrideWithValue(llm),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  tearDown(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  group('terminal input guard', () {
    test('strips Ctrl+C when blocking is on', () {
      final blocked = TerminalInputGuard.filter(
        'ab${TerminalInputGuard.ctrlC}c',
        blockInterrupt: true,
      );
      expect(blocked.blockedInterrupt, isTrue);
      expect(blocked.data, 'abc');
      expect(blocked.data.contains(TerminalInputGuard.ctrlC), isFalse);
    });

    test('passes Ctrl+C when blocking is off', () {
      final open = TerminalInputGuard.filter(
        TerminalInputGuard.ctrlC,
        blockInterrupt: false,
      );
      expect(open.blockedInterrupt, isFalse);
      expect(open.data, TerminalInputGuard.ctrlC);
    });

    test('also strips Ctrl+backslash, which kills via SIGQUIT', () {
      final blocked = TerminalInputGuard.filter(
        'a${TerminalInputGuard.ctrlBackslash}b',
        blockInterrupt: true,
      );
      expect(blocked.blockedInterrupt, isTrue);
      expect(blocked.data, 'ab');

      final both = TerminalInputGuard.filter(
        '${TerminalInputGuard.ctrlC}x${TerminalInputGuard.ctrlBackslash}',
        blockInterrupt: true,
      );
      expect(both.data, 'x');
    });

    test('ctrl latch maps a plain key to its control code', () {
      // Soft keyboards send letters; the latch is what turns them into Ctrl+X.
      expect(TerminalInputGuard.applyCtrlLatch('c'), '\x03');
      expect(TerminalInputGuard.applyCtrlLatch('C'), '\x03');
      expect(TerminalInputGuard.applyCtrlLatch('d'), '\x04');
      expect(TerminalInputGuard.applyCtrlLatch('z'), '\x1a');
      expect(TerminalInputGuard.applyCtrlLatch('['), '\x1b');
      expect(TerminalInputGuard.applyCtrlLatch('?'), '\x7f');
      // Nothing sensible to map → leave the input alone.
      expect(TerminalInputGuard.applyCtrlLatch('1'), isNull);
      expect(TerminalInputGuard.applyCtrlLatch('ab'), isNull);
      expect(TerminalInputGuard.applyCtrlLatch(''), isNull);
    });
  });

  group('shell quoting', () {
    test('escapes single quotes for untrusted names', () {
      expect(shellSingleQuote('foo'), "'foo'");
      expect(shellSingleQuote("a'b"), "'a'\"'\"'b'");
      // tmux commands must not interpolate raw quotes.
      const tmux = TmuxService();
      expect(tmux.newSessionCommand("job'x"), contains("'\"'\"'"));
      expect(tmux.attachSessionCommand('s1'), "tmux attach-session -t 's1'\n");
    });
  });

  group('command risk', () {
    const c = CommandRiskClassifier();

    test('blocks empty and control chars', () {
      expect(c.classify('').risk, CommandRisk.blocked);
      expect(c.classify('echo\x00x').risk, CommandRisk.blocked);
    });

    test('flags destructive patterns and max rank', () {
      expect(c.classify('rm -rf /tmp/x').risk, CommandRisk.high);
      expect(c.classify('sudo apt install foo').risk, CommandRisk.medium);
      expect(c.classify('ls -la').risk, CommandRisk.low);
      expect(
        CommandRisk.max(CommandRisk.low, CommandRisk.high),
        CommandRisk.high,
      );
    });

    test('flags file writes however they are spelled', () {
      // Spacing around the redirect is optional to the shell, so it must be
      // optional to the classifier too.
      for (final cmd in [
        'echo hi > out.txt',
        'echo hi >out.txt',
        'echo hi>out.txt',
        'echo hi >> out.log',
        'echo hi>>out.log',
        'cat a | tee /etc/hosts',
      ]) {
        expect(c.classify(cmd).risk, CommandRisk.medium, reason: cmd);
      }
    });

    test('does not mistake fd dup or operators for a write', () {
      for (final cmd in [
        'make 2>&1 | less',
        'python -c "print(1 if a >= b else 2)"',
        'awk "{print}" | grep -- "->"',
      ]) {
        expect(c.classify(cmd).risk, CommandRisk.low, reason: cmd);
      }
    });
  });

  group('transcript buffer', () {
    test('strips ansi, redacts secrets, respects line limit', () {
      final buf = TerminalTranscriptBuffer(maxLines: 50, maxBytes: 10 * 1024);
      buf.append('\x1B[31mred\x1B[0m\n');
      buf.append('password=supersecret\n');
      buf.append('Bearer abcdefghijklmnop\n');
      buf.append('sk-abcdefghijklmnop\n');
      final recent = buf.recentForAi(20);
      expect(recent.contains('red'), isTrue);
      expect(recent.contains('\x1B'), isFalse);
      expect(recent.contains('supersecret'), isFalse);
      expect(recent.contains('***REDACTED***'), isTrue);
      expect(recent.contains('***REDACTED_KEY***'), isTrue);

      final small = TerminalTranscriptBuffer(maxLines: 5, maxBytes: 10 * 1024);
      for (var i = 0; i < 20; i++) {
        small.append('line-$i\n');
      }
      expect(small.lineCount, lessThanOrEqualTo(5));
      final tail = small.recentForAi(5);
      expect(tail.contains('line-19'), isTrue);
      expect(tail.contains('line-0'), isFalse);
    });

    test('a progress bar redrawing itself stays one line', () {
      // tqdm & friends redraw with a bare \r. Treating each redraw as a new
      // line evicted everything else from the AI context window.
      final buf = TerminalTranscriptBuffer(maxLines: 10, maxBytes: 64 * 1024);
      buf.append('IMPORTANT: checkpoint saved to /data/ckpt\n');
      for (var i = 0; i <= 100; i++) {
        buf.append('\rEpoch 1: $i%');
      }
      buf.append('\n');

      expect(buf.lineCount, 2);
      final recent = buf.recentForAi(10);
      expect(recent, contains('IMPORTANT: checkpoint saved'));
      // Only the last redraw survives, and no stray CR reaches the model.
      expect(recent, contains('Epoch 1: 100%'));
      expect(recent, isNot(contains('Epoch 1: 99%')));
      expect(recent, isNot(contains('\r')));
    });

    test('CRLF is one newline even when split across chunks', () {
      final buf = TerminalTranscriptBuffer();
      buf.append('a\r');
      buf.append('\nb\r\nc');
      expect(buf.recentForAi(10), 'a\nb\nc');
    });

    test('keeps stream chunks on one line before redacting secrets', () {
      final buf = TerminalTranscriptBuffer();
      buf.append('pass');
      buf.append('word=hunter2');

      final recent = buf.recentForAi(20);
      expect(recent, contains('password=***REDACTED***'));
      expect(recent, isNot(contains('hunter2')));
      expect(buf.lineCount, 1);
    });
  });

  group('tmux parse', () {
    const tmux = TmuxService();

    test('parses list-sessions TSV', () {
      final list = tmux.parseListSessions('train\t1\t3\njob:1\t0\t1\n');
      expect(list.length, 2);
      expect(list.first.name, 'train');
      expect(list.first.attached, 1);
      expect(list.first.windows, 3);
    });

    test('detach goes through exec, not blind prefix keys', () async {
      final fake = _FakeSshClient()..connected = true;
      await tmux.detachSession(fake, 'train');
      // Writing `C-b d` into the PTY is only meaningful inside tmux; outside it
      // the bytes land in the user's command line.
      expect(fake.writes, isEmpty);
      expect(fake.execCommands.single, "tmux detach-client -s 'train'");
      // The session itself must survive — jobs keep running.
      expect(fake.execCommands.single, isNot(contains('kill')));
    });

    test('detach quotes hostile session names', () {
      expect(tmux.detachClientCommand("a'b"), contains("'\"'\"'"));
    });

    test('a session named like an error is not mistaken for one', () async {
      final fake = _FakeSshClient()
        ..connected = true
        ..execResult = 'command not found\t1\t2\n';
      final list = await tmux.listSessions(fake);
      expect(list.single.name, 'command not found');
      expect(list.single.attached, 1);
    });

    test('switch-client when already in tmux; attach when not', () async {
      final fake = _FakeSshClient()..connected = true;
      await tmux.switchOrAttachInShell(fake, 'other', currentlyInTmux: true);
      expect(
        fake.writes.any((w) => w.contains('switch-client -t other')),
        isTrue,
      );

      fake.writes.clear();
      await tmux.switchOrAttachInShell(fake, 'fresh', currentlyInTmux: false);
      expect(fake.writes.single, contains('attach-session'));
      expect(fake.writes.single, contains('fresh'));
    });

    test('distinguishes missing tmux from an empty server', () async {
      final fake = _FakeSshClient()..connected = true;

      fake.execError = ResearchSshExecException(
        exitCode: 127,
        stdoutText: '',
        stderrText: 'bash: tmux: command not found',
      );
      expect(
        () => tmux.listSessions(fake),
        throwsA(isA<TmuxNotInstalledException>()),
      );

      fake.execError = ResearchSshExecException(
        exitCode: 1,
        stdoutText: '',
        stderrText: 'no server running on /tmp/tmux-1000/default',
      );
      expect(await tmux.listSessions(fake), isEmpty);
    });

    test('create surfaces a non-zero remote exit', () {
      final fake = _FakeSshClient()
        ..connected = true
        ..execError = ResearchSshExecException(
          exitCode: 1,
          stdoutText: '',
          stderrText: 'permission denied',
        );

      expect(
        () => tmux.createSession(fake, 'train'),
        throwsA(isA<ResearchSshExecException>()),
      );
    });
  });

  group('copilot parse + approval gate', () {
    test('parse failure yields no execute offer', () async {
      final copilot = ResearchCopilotService(_ScriptLlm('not json at all'));
      final p = await copilot.analyze(
        config: const LlmConfig(
          baseUrl: 'https://example.com',
          apiKey: 'k',
          model: 'm',
        ),
        transcriptPreview: 'ls',
        proposalId: 'p1',
      );
      expect(p.parseOk, isFalse);
      expect(p.canOfferExecute, isFalse);
    });

    test(
      'valid json proposal can offer execute; local risk floors model',
      () async {
        final copilot = ResearchCopilotService(
          _ScriptLlm(
            jsonEncode({
              'diagnosis': 'ok',
              'command': 'rm -rf /tmp/x',
              'risk': 'low',
              'evidence': ['gpu'],
              'impacts': ['delete'],
              'nonImpacts': [],
              'rollback': null,
            }),
          ),
        );
        final p = await copilot.analyze(
          config: const LlmConfig(
            baseUrl: 'https://example.com',
            apiKey: 'k',
            model: 'm',
          ),
          transcriptPreview: 'prompt',
          proposalId: 'p2',
        );
        expect(p.parseOk, isTrue);
        expect(p.canOfferExecute, isTrue);
        // Model said low; local classifier must raise to high.
        expect(p.risk, CommandRisk.high);
      },
    );

    test('ApprovedCommandExecutor rejects generation / host mismatch', () {
      final writes = <List<int>>[];
      const executor = ApprovedCommandExecutor();
      expect(
        () => executor.execute(
          writeToShell: writes.add,
          approved: const ApprovedCommand(
            proposalId: 'p',
            hostId: 'h1',
            connectionGeneration: 1,
            command: 'echo hi',
            risk: CommandRisk.low,
            cwdHint: '/',
          ),
          activeHostId: 'h1',
          activeConnectionGeneration: 2,
        ),
        throwsStateError,
      );
      expect(writes, isEmpty);

      expect(
        () => executor.execute(
          writeToShell: writes.add,
          approved: const ApprovedCommand(
            proposalId: 'p',
            hostId: 'h1',
            connectionGeneration: 1,
            command: 'echo hi',
            risk: CommandRisk.low,
            cwdHint: '/',
          ),
          activeHostId: 'other',
          activeConnectionGeneration: 1,
        ),
        throwsStateError,
      );
      expect(writes, isEmpty);
    });

    test('ApprovedCommandExecutor writes only matching approved command', () {
      final writes = <List<int>>[];
      const ApprovedCommandExecutor().execute(
        writeToShell: writes.add,
        approved: const ApprovedCommand(
          proposalId: 'p',
          hostId: 'h1',
          connectionGeneration: 3,
          command: 'echo hi',
          risk: CommandRisk.low,
          cwdHint: '/',
        ),
        activeHostId: 'h1',
        activeConnectionGeneration: 3,
      );
      expect(writes.single, utf8.encode('echo hi\n'));
    });

    test('ApprovedCommandExecutor encodes non-ASCII as UTF-8 bytes', () {
      final writes = <List<int>>[];
      const ApprovedCommandExecutor().execute(
        writeToShell: writes.add,
        approved: const ApprovedCommand(
          proposalId: 'p',
          hostId: 'h1',
          connectionGeneration: 1,
          command: 'cat 中文路径/日志.txt',
          risk: CommandRisk.low,
          cwdHint: '/',
        ),
        activeHostId: 'h1',
        activeConnectionGeneration: 1,
      );
      expect(writes.single, utf8.encode('cat 中文路径/日志.txt\n'));
      // Must not be UTF-16 code units (would differ for CJK).
      expect(writes.single, isNot(equals('cat 中文路径/日志.txt\n'.codeUnits)));
    });

    test('CommandProposal is not an ApprovedCommand', () {
      const proposal = CommandProposal(
        id: 'x',
        diagnosis: 'd',
        command: 'rm -rf /',
        risk: CommandRisk.high,
        evidence: [],
        impacts: [],
        nonImpacts: [],
      );
      expect(proposal, isNot(isA<ApprovedCommand>()));
      expect(proposal.canOfferExecute, isTrue);
    });

    test('edited command recomputes local risk', () {
      final copilot = ResearchCopilotService(_ScriptLlm(''));
      const base = CommandProposal(
        id: 'e',
        diagnosis: 'd',
        command: 'ls',
        risk: CommandRisk.low,
        evidence: [],
        impacts: [],
        nonImpacts: [],
      );
      final edited = copilot.withEditedCommand(base, 'sudo reboot');
      expect(edited.risk, CommandRisk.high);
      expect(edited.command, 'sudo reboot');
    });
  });

  group('settings researchMode default', () {
    test('defaults false and persists toggle', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = _baseContainer(prefs: prefs);
      addTearDown(container.dispose);

      final state = await container.read(settingsControllerProvider.future);
      expect(state.researchModeEnabled, isFalse);

      await container
          .read(settingsControllerProvider.notifier)
          .setResearchModeEnabled(true);
      expect(
        container.read(settingsControllerProvider).value!.researchModeEnabled,
        isTrue,
      );
      expect(prefs.getBool('researchModeEnabled'), isTrue);

      await container
          .read(settingsControllerProvider.notifier)
          .setResearchModeEnabled(false);
      expect(
        container.read(settingsControllerProvider).value!.researchModeEnabled,
        isFalse,
      );
    });
  });

  group('shell tab visibility', () {
    test('hides terminal unless research on', () {
      expect(ShellTab.visible(researchModeEnabled: false), [
        ShellTab.chat,
        ShellTab.studio,
        ShellTab.settings,
      ]);
      expect(ShellTab.visible(researchModeEnabled: true), [
        ShellTab.chat,
        ShellTab.terminal,
        ShellTab.studio,
        ShellTab.settings,
      ]);
    });

    test('ensureVisible falls back from terminal to settings', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(shellTabProvider.notifier).set(ShellTab.terminal);
      expect(container.read(shellTabProvider), ShellTab.terminal);
      container
          .read(shellTabProvider.notifier)
          .ensureVisible(ShellTab.visible(researchModeEnabled: false));
      expect(container.read(shellTabProvider), ShellTab.settings);
    });
  });

  group('research terminal controller (fake transport)', () {
    late ProviderContainer container;
    late _FakeSshClient fake;
    late SharedPreferences prefs;

    const profile = SshProfile(
      id: 'host1',
      name: 'lab',
      host: '127.0.0.1',
      username: 'u',
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      prefs = await SharedPreferences.getInstance();
      fake = _FakeSshClient();
      container = _baseContainer(
        prefs: prefs,
        llm: _ScriptLlm(
          jsonEncode({
            'diagnosis': 'ok',
            'command': 'echo 1',
            'risk': 'low',
            'evidence': <String>[],
            'impacts': <String>[],
            'nonImpacts': <String>[],
          }),
        ),
      );
      // Warm provider and inject fake transport.
      container.read(researchTerminalProvider);
      container
          .read(researchTerminalProvider.notifier)
          .debugSetClientFactory(() => fake);
      await container
          .read(researchTerminalProvider.notifier)
          .saveProfile(profile, password: 'secret-never-log');
    });

    tearDown(() async {
      // Explicit disconnect before dispose so releaseAll is quiet.
      try {
        await container.read(researchTerminalProvider.notifier).disconnect();
      } catch (_) {}
      container.dispose();
    });

    test(
      'connect pipes output, resize syncs PTY, disconnect cleans up',
      () async {
        final ctrl = container.read(researchTerminalProvider.notifier);
        ctrl.setHostKeyHandlers(
          onTrust: (_) async => true,
          onMismatch: (_, _) async => false,
        );
        await ctrl.connect(profile);
        final st = container.read(researchTerminalProvider);
        expect(st.isConnected, isTrue);
        expect(st.status, ResearchConnectionStatus.connected);
        final gen1 = st.connectionGeneration;
        expect(gen1, greaterThan(0));

        fake.pushStdout('hello-from-pty\n');
        await Future<void>.delayed(Duration.zero);
        expect(ctrl.previewForAi(), contains('hello-from-pty'));

        // User keyboard path
        ctrl.sendShortcut('pwd\n');
        expect(fake.writes.any((w) => w.contains('pwd')), isTrue);

        // Default blockCtrlC should strip ETX.
        fake.writes.clear();
        expect(container.read(researchTerminalProvider).blockCtrlC, isTrue);
        final blocked = ctrl.writeUserInput(TerminalInputGuard.ctrlC);
        expect(blocked, isTrue);
        expect(fake.writes, isEmpty);
        ctrl.sendCtrlCForced();
        expect(fake.writes, [TerminalInputGuard.ctrlC]);

        ctrl.terminal.onResize?.call(120, 40, 0, 0);
        expect(fake.cols, 120);
        expect(fake.rows, 40);

        await ctrl.disconnect();
        final after = container.read(researchTerminalProvider);
        expect(after.isConnected, isFalse);
        expect(after.connectionGeneration, greaterThan(gen1));
        expect(after.proposal, isNull);
        expect(fake.disconnectCount, greaterThan(0));
      },
    );

    test('stream decoder preserves UTF-8 split across SSH chunks', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);

      final bytes = utf8.encode('中文输出\n');
      fake.pushStdoutBytes(bytes.sublist(0, 2));
      fake.pushStdoutBytes(bytes.sublist(2));
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.previewForAi(), contains('中文输出'));
      expect(ctrl.previewForAi(), isNot(contains('�')));
    });

    test('cancelled connect cannot restore a stale connected state', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      fake.connectCompleter = Completer<void>();

      final pendingConnect = ctrl.connect(profile);
      await Future<void>.delayed(Duration.zero);
      await ctrl.disconnect();
      fake.connectCompleter!.complete();
      await pendingConnect;

      final current = container.read(researchTerminalProvider);
      expect(current.status, ResearchConnectionStatus.disconnected);
      expect(current.isConnected, isFalse);
      expect(fake.connected, isFalse);
    });

    test('editing or deleting the active endpoint disconnects first', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      final connectedGeneration = container
          .read(researchTerminalProvider)
          .connectionGeneration;

      await ctrl.saveProfile(profile.copyWith(host: '10.0.0.2'));
      final afterEdit = container.read(researchTerminalProvider);
      expect(afterEdit.isConnected, isFalse);
      expect(afterEdit.activeProfile?.host, '10.0.0.2');
      expect(afterEdit.connectionGeneration, greaterThan(connectedGeneration));

      await ctrl.connect(afterEdit.activeProfile!);
      expect(container.read(researchTerminalProvider).isConnected, isTrue);
      await ctrl.deleteProfile(profile.id);
      final afterDelete = container.read(researchTerminalProvider);
      expect(afterDelete.isConnected, isFalse);
      expect(afterDelete.activeProfileId, isNull);
      expect(afterDelete.profiles, isEmpty);
    });

    test('saving another profile does not relabel a live connection', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      await ctrl.saveProfile(
        const SshProfile(
          id: 'host2',
          name: 'other',
          host: '10.0.0.2',
          username: 'u2',
        ),
        password: 'other-secret',
      );

      final live = container.read(researchTerminalProvider);
      expect(live.isConnected, isTrue);
      expect(live.activeProfileId, profile.id);
      expect(live.activeProfile?.host, profile.host);
    });

    test('stale tmux refresh cannot overwrite a newer connection', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      final fakeA = _FakeSshClient();
      final fakeB = _FakeSshClient();
      var factoryCalls = 0;
      ctrl.debugSetClientFactory(() => factoryCalls++ == 0 ? fakeA : fakeB);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      await Future<void>.delayed(Duration.zero);

      fakeA.execCompleter = Completer<String>();
      final staleRefresh = ctrl.refreshTmux();
      await Future<void>.delayed(Duration.zero);

      const other = SshProfile(
        id: 'host2',
        name: 'other',
        host: '10.0.0.2',
        username: 'u2',
      );
      await ctrl.saveProfile(other, password: 'other-secret');
      await ctrl.connect(other);
      fakeA.execCompleter!.complete('old-session\t1\t2\n');
      await staleRefresh;
      await Future<void>.delayed(Duration.zero);

      final live = container.read(researchTerminalProvider);
      expect(live.activeProfileId, other.id);
      expect(
        live.tmuxSessions.map((s) => s.name),
        isNot(contains('old-session')),
      );
    });

    test('stale tmux create never attaches on a newer host', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      final fakeA = _FakeSshClient();
      final fakeB = _FakeSshClient();
      var factoryCalls = 0;
      ctrl.debugSetClientFactory(() => factoryCalls++ == 0 ? fakeA : fakeB);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      await Future<void>.delayed(Duration.zero);

      fakeA.execCompleter = Completer<String>();
      final staleCreate = ctrl.createTmuxSession('train');
      await Future<void>.delayed(Duration.zero);

      const other = SshProfile(
        id: 'host2',
        name: 'other',
        host: '10.0.0.2',
        username: 'u2',
      );
      await ctrl.saveProfile(other, password: 'other-secret');
      await ctrl.connect(other);
      fakeA.execCompleter!.complete('');
      await staleCreate;

      expect(fakeB.writes.any((w) => w.contains('attach-session')), isFalse);
      expect(container.read(researchTerminalProvider).currentTmuxName, isNull);
    });

    test('ctrl latch reaches the soft-keyboard input path', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      fake.writes.clear();

      // Soft keyboards deliver plain text through terminal.onOutput; the
      // shortcut bar's Ctrl chip never sees it, so the latch must live here.
      ctrl.setCtrlLatched(true);
      ctrl.terminal.onOutput!('d');
      expect(fake.writes, ['\x04']);
      expect(container.read(researchTerminalProvider).ctrlLatched, isFalse);

      // Latch is one-shot, exactly like a real Ctrl key release.
      fake.writes.clear();
      ctrl.terminal.onOutput!('d');
      expect(fake.writes, ['d']);

      // Nothing sensible to map: send the key through untouched.
      fake.writes.clear();
      ctrl.setCtrlLatched(true);
      ctrl.terminal.onOutput!('1');
      expect(fake.writes, ['1']);
    });

    test('latched Ctrl+C is still blocked, and flags the UI', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      fake.writes.clear();

      expect(container.read(researchTerminalProvider).blockCtrlC, isTrue);
      ctrl.setCtrlLatched(true);
      ctrl.terminal.onOutput!('c');
      expect(fake.writes, isEmpty);
      expect(
        container.read(researchTerminalProvider).interruptBlockedFlash,
        isTrue,
      );

      ctrl.clearInterruptBlockedFlash();
      expect(
        container.read(researchTerminalProvider).interruptBlockedFlash,
        isFalse,
      );
    });

    test('refresh drops a tmux session we are no longer attached to', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      // Let connect's own tmux refresh land before staging our own.
      await Future<void>.delayed(Duration.zero);
      ctrl.attachTmuxSession('train');
      expect(container.read(researchTerminalProvider).currentTmuxName, 'train');

      fake.execResult = 'train\t1\t1\n';
      await ctrl.refreshTmux();
      expect(container.read(researchTerminalProvider).currentTmuxName, 'train');

      // User left tmux behind our back (`exit`, or C-b d on a real keyboard).
      fake.execResult = 'train\t0\t1\n';
      await ctrl.refreshTmux();
      expect(container.read(researchTerminalProvider).currentTmuxName, isNull);

      // Session killed outright.
      ctrl.attachTmuxSession('train');
      fake.execResult = 'other\t1\t1\n';
      await ctrl.refreshTmux();
      expect(container.read(researchTerminalProvider).currentTmuxName, isNull);
    });

    test('detach is a no-op when nothing is attached', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      await Future<void>.delayed(Duration.zero);
      fake.writes.clear();
      fake.execCommands.clear();

      await ctrl.detachTmuxSession();
      // The old prefix-key write would have dropped `C-b d` into the shell.
      expect(fake.writes, isEmpty);
      expect(fake.execCommands, isEmpty);

      ctrl.attachTmuxSession('train');
      fake.writes.clear();
      fake.execCommands.clear();
      await ctrl.detachTmuxSession();
      expect(fake.execCommands.single, contains('detach-client -s'));
      expect(container.read(researchTerminalProvider).currentTmuxName, isNull);
    });

    test('an illegal tmux name surfaces as tmuxError, not a crash', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      await Future<void>.delayed(Duration.zero);

      await ctrl.createTmuxSession('bad name!');
      final st = container.read(researchTerminalProvider);
      expect(st.tmuxError, contains('非法'));
      expect(st.currentTmuxName, isNull);
      expect(fake.writes.any((w) => w.contains('attach-session')), isFalse);
    });

    test('clearing host key handlers only unbinds its own', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      Future<bool> mineTrust(ResearchHostKeyInfo i) async => true;
      Future<bool> mineMismatch(ResearchHostKeyInfo i, String p) async => true;
      Future<bool> theirsTrust(ResearchHostKeyInfo i) async => true;
      Future<bool> theirsMismatch(ResearchHostKeyInfo i, String p) async => true;

      ctrl.setHostKeyHandlers(onTrust: mineTrust, onMismatch: mineMismatch);
      // A page disposing after a newer one bound its own must not clear it.
      ctrl.clearHostKeyHandlers(
        onTrust: theirsTrust,
        onMismatch: theirsMismatch,
      );
      await ctrl.connect(profile);
      expect(container.read(researchTerminalProvider).isConnected, isTrue);
      await ctrl.disconnect();

      // Its own handlers do get dropped — no dialogs on a dead context.
      ctrl.clearHostKeyHandlers(onTrust: mineTrust, onMismatch: mineMismatch);
      const untrusted = SshProfile(
        id: 'host3',
        name: 'fresh',
        host: '10.0.0.3',
        username: 'u3',
      );
      await ctrl.saveProfile(untrusted);
      await ctrl.connect(untrusted);
      expect(
        container.read(researchTerminalProvider).status,
        ResearchConnectionStatus.error,
      );
    });

    test('approval binds to host+generation; reconnect invalidates', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);

      ctrl.debugSetProposal(
        const CommandProposal(
          id: 'prop-1',
          diagnosis: 'need echo',
          command: 'echo approved',
          risk: CommandRisk.low,
          evidence: ['t'],
          impacts: ['print'],
          nonImpacts: [],
        ),
      );

      final approved = ctrl.approveCurrentProposal(
        command: 'echo approved',
        cwdHint: '/',
      );
      expect(approved, isNotNull);
      expect(approved!.hostId, 'host1');
      final gen = approved.connectionGeneration;

      // Happy path write
      fake.writes.clear();
      ctrl.executeApproved(approved);
      expect(fake.writes, ['echo approved\n']);
      // Proposal cleared after execute
      expect(container.read(researchTerminalProvider).proposal, isNull);

      // Reconnect bumps generation — old approval must fail.
      await ctrl.disconnect();
      await ctrl.connect(profile);
      expect(
        container.read(researchTerminalProvider).connectionGeneration,
        isNot(gen),
      );
      expect(() => ctrl.executeApproved(approved), throwsA(isA<StateError>()));
    });

    test('unapproved proposal cannot execute; blocked risk refused', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);

      // No proposal → null approval
      expect(
        ctrl.approveCurrentProposal(command: 'echo x', cwdHint: '/'),
        isNull,
      );

      ctrl.debugSetProposal(
        const CommandProposal(
          id: 'bad',
          diagnosis: 'parse fail',
          command: '',
          risk: CommandRisk.blocked,
          evidence: [],
          impacts: [],
          nonImpacts: [],
          parseOk: false,
        ),
      );
      expect(
        ctrl.approveCurrentProposal(command: 'echo x', cwdHint: '/'),
        isNull,
      );

      // parseOk but empty/blocked local
      ctrl.debugSetProposal(
        const CommandProposal(
          id: 'okish',
          diagnosis: 'd',
          command: 'echo x',
          risk: CommandRisk.low,
          evidence: [],
          impacts: [],
          nonImpacts: [],
        ),
      );
      expect(ctrl.approveCurrentProposal(command: '', cwdHint: '/'), isNull);
    });

    test('password never lands in SharedPreferences profile JSON', () {
      final raw = prefs.getString(ResearchPrefs.profilesKey);
      expect(raw, isNotNull);
      expect(raw!.contains('secret-never-log'), isFalse);
      expect(raw.contains('host1'), isTrue);
      final list = SshProfile.listFromJson(raw);
      expect(list.single.host, '127.0.0.1');
    });

    test('host key reject prevents connect', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => false,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      final st = container.read(researchTerminalProvider);
      expect(st.isConnected, isFalse);
      expect(st.status, ResearchConnectionStatus.error);
    });

    test('releaseAll disconnects client', () async {
      final ctrl = container.read(researchTerminalProvider.notifier);
      ctrl.setHostKeyHandlers(
        onTrust: (_) async => true,
        onMismatch: (_, _) async => false,
      );
      await ctrl.connect(profile);
      expect(fake.connected, isTrue);
      await ctrl.releaseAll();
      expect(fake.connected, isFalse);
      expect(container.read(researchTerminalProvider).isConnected, isFalse);
    });
  });

  group('web stub client', () {
    test('createResearchSshClient on this platform is usable or stub', () async {
      // Factory always returns something implementing the interface.
      final client = createResearchSshClient();
      expect(client.isConnected, isFalse);
      // On IO platforms connect may attempt real TCP; we only assert disconnect is safe.
      await client.disconnect();
    });

    test('a reconnect does not reuse the streams disconnect closed', () async {
      final client = createResearchSshClient();
      await client.disconnect();

      // Port 1 refuses immediately; all we need is for connect() to get far
      // enough to reopen its output streams before failing on the socket.
      const dead = SshProfile(
        id: 'x',
        name: 'x',
        host: '127.0.0.1',
        port: 1,
        username: 'u',
      );
      await expectLater(
        client.connect(
          profile: dead,
          password: null,
          privateKeyPem: null,
          passphrase: null,
          onHostKeyTrust: (_) async => true,
          onHostKeyMismatch: (_, _) async => false,
          connectTimeout: const Duration(seconds: 2),
        ),
        throwsA(anything),
      );

      var closed = false;
      final sub = client.stdout.listen((_) {}, onDone: () => closed = true);
      await Future<void>.delayed(Duration.zero);
      // A closed controller hands every later listener an immediate done, so
      // the reconnected session's output would silently never arrive.
      expect(closed, isFalse);
      await sub.cancel();
      await client.disconnect();
    });
  });

  group('static product gates', () {
    test('research terminal page and settings card exist in tree sources', () {
      // Structural checks against shipped sources (package root = CWD).
      final terminal = File(
        'lib/features/research/research_terminal_page.dart',
      ).readAsStringSync();
      final settings = File(
        'lib/features/settings/settings_page.dart',
      ).readAsStringSync();
      final shell = File(
        'lib/features/shell/app_shell.dart',
      ).readAsStringSync();

      expect(terminal.contains('ResearchTerminalPage'), isTrue);
      expect(terminal.contains('approveCurrentProposal'), isTrue);
      expect(terminal.contains('executeApproved'), isTrue);
      expect(terminal.contains('总是允许'), isFalse);
      expect(terminal.contains('自动执行'), isFalse);

      expect(settings.contains('科研模式'), isTrue);
      expect(settings.contains('实验功能'), isTrue);
      expect(settings.contains('setResearchModeEnabled'), isTrue);

      expect(shell.contains('ShellTab.terminal'), isTrue);
      expect(shell.contains('researchModeEnabled'), isTrue);
    });
  });
}
