import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/research/ssh_profile.dart';
import '../../state/research_terminal_controller.dart';
import '../../features/tui_bridge/protocol.dart';
import '../research/research_files.dart';
import '../research/research_workspace.dart';
import '../workbench/terminal/terminal_connection.dart';
import 'terminal_output.dart';
import 'wire_models.dart';

class HostResearchService {
  HostResearchService(this.container);
  final ProviderContainer container;
  ResearchTerminalController get controller =>
      container.read(researchTerminalProvider.notifier);
  final _sessions =
      <String, ({String scope, ResearchWorkspaceSession session})>{};
  final _calls =
      <
        String,
        ({String scope, CancelToken token, HostTerminalOutput output})
      >{};
  final _terminals = <String, _OwnedTerminal>{};
  final _transfers = <String, _OwnedTransfer>{};
  bool get hasActiveTransfers => _transfers.values.any((t) => !t.done);
  void _connection(Map<String, dynamic> args) {
    final current = container.read(researchTerminalProvider);
    if (args['generation'] != current.connectionGeneration ||
        args['profile'] != current.activeProfileId) {
      throw const BridgeFailure('stale_connection', 'SSH 连接已变化，旧操作未执行');
    }
  }

  ResearchWorkspaceSession _session(String id, String scope) {
    final value = _sessions[id];
    if (value == null || value.scope != scope) {
      throw const BridgeFailure('not_found', '远程工作区已关闭');
    }
    value.session.validate();
    return value.session;
  }

  Future<Object?> invoke(
    String operation,
    Map<String, dynamic> a,
    String scope,
  ) async {
    String string(String key) => requiredString(a, key);
    switch (operation) {
      case 'reloadProfiles':
        await controller.reloadProfiles();
      case 'saveProfile':
        await controller.saveProfile(
          SshProfile.fromJson(wireMap(a['value'])) ??
              (throw const FormatException('SSH 配置无效')),
          password: a['password'] as String?,
          privateKeyPem: a['privateKeyPem'] as String?,
          passphrase: a['passphrase'] as String?,
        );
      case 'deleteProfile':
        await controller.deleteProfile(string('id'));
      case 'connect':
        await controller.connect(
          SshProfile.fromJson(wireMap(a['value'])) ??
              (throw const FormatException('SSH 配置无效')),
        );
      case 'testProfile':
        final result = await controller.testProfile(
          SshProfile.fromJson(wireMap(a['value'])) ??
              (throw const FormatException('SSH 配置无效')),
          password: a['password'] as String?,
          privateKeyPem: a['privateKeyPem'] as String?,
          passphrase: a['passphrase'] as String?,
        );
        return {
          'elapsed': result.elapsed.inMicroseconds,
          'fingerprint': result.fingerprint,
        };
      case 'aiContext':
        await controller.setAiContextLines(a['value'] as int);
      case 'blockCtrlC':
        await controller.setBlockCtrlC(a['value'] as bool);
      case 'disconnect':
        _connection(a);
        await controller.disconnect();
      case 'releaseAll':
        _connection(a);
        await controller.releaseAll();
      case 'input':
        _connection(a);
        final data = a['data'] as String;
        if (data.length > 65536) {
          throw const BridgeFailure('too_large', '请分批发送终端输入');
        }
        return controller.writeUserInput(data, force: a['force'] == true);
      case 'resize':
        _connection(a);
        controller.resizeRemote(a['cols'] as int, a['rows'] as int);
      case 'ctrlLatch':
        _connection(a);
        controller.setCtrlLatched(a['value'] as bool);
      case 'clearInterrupt':
        controller.clearInterruptBlockedFlash();
      case 'refreshTmux':
        _connection(a);
        await controller.refreshTmux();
      case 'createTmux':
        _connection(a);
        await controller.createTmuxSession(string('name'));
      case 'switchTmux':
        _connection(a);
        await controller.switchTmuxSession(string('name'));
      case 'detachTmux':
        _connection(a);
        await controller.detachTmuxSession();
      case 'analyze':
        _connection(a);
        await controller.analyzeWithAi(userGoal: a['goal'] as String?);
      case 'clearProposal':
        _connection(a);
        controller.clearProposal();
      case 'editProposal':
        _connection(a);
        if (container.read(researchTerminalProvider).proposal?.id !=
            a['proposalId']) {
          throw const BridgeFailure('conflict', '命令提案已改变');
        }
        controller.editProposalCommand(a['command'] as String);
      case 'executeApproved':
        _connection(a);
        if (container.read(researchTerminalProvider).proposal?.id !=
            a['proposalId']) {
          throw const BridgeFailure('conflict', '命令提案已改变');
        }
        final approved = controller.approveCurrentProposal(
          command: string('command'),
          cwdHint: a['cwdHint'] as String? ?? '',
        );
        if (approved == null) throw const BridgeFailure('forbidden', '命令审批无效');
        controller.executeApproved(approved);
      case 'work.open':
        _connection(a);
        if (_sessions.length >= 64) {
          throw const BridgeFailure('busy', '远程工作区数量已达上限');
        }
        final session = await controller.openWorkSession(
          string('profile'),
          string('root'),
        );
        final id = const Uuid().v4();
        _sessions[id] = (scope: scope, session: session);
        return {'id': id, 'root': session.root, 'label': session.label};
      case 'work.close':
        final id = string('id');
        final session = _session(id, scope);
        _sessions.remove(id);
        await session.close();
      case 'work.call':
        final session = _session(string('id'), scope), id = string('callId');
        if (_calls.containsKey(id) || _calls.length >= 128) {
          throw const BridgeFailure('busy', '远程操作标识重复或数量超限');
        }
        final token = CancelToken(), output = HostTerminalOutput();
        _calls[id] = (scope: scope, token: token, output: output);
        try {
          return await session.call(
            string('tool'),
            wireMap(a['arguments']),
            token,
            onOutput: (text, isStderr) => output.add(text),
          );
        } finally {
          Timer(const Duration(minutes: 1), () => _calls.remove(id));
        }
      case 'terminal.open':
        final session = _session(string('id'), scope);
        if (session.openTerminal == null) {
          throw const BridgeFailure('unsupported', '远端不支持交互终端');
        }
        if (_terminals.length >= 32) {
          throw const BridgeFailure('busy', '交互终端数量已达上限');
        }
        final terminal = await session.openTerminal!(
          a['cols'] as int,
          a['rows'] as int,
        );
        final id = const Uuid().v4();
        _terminals[id] = _OwnedTerminal(scope, terminal);
        return {'id': id};
      case 'terminal.write':
        final t = _terminal(string('id'), scope);
        final data = base64Decode(string('bytes'));
        if (data.length > 65536) {
          throw const BridgeFailure('too_large', '终端输入超限');
        }
        await t.terminal.write(data);
      case 'terminal.resize':
        _terminal(
          string('id'),
          scope,
        ).terminal.resize(a['cols'] as int, a['rows'] as int);
      case 'terminal.close':
        final id = string('id');
        final t = _terminal(id, scope);
        _terminals.remove(id);
        await t.close();
      case 'files.absolute':
        _connection(a);
        return controller.files.absolute(string('path'));
      case 'files.list':
        _connection(a);
        return (await controller.files.list(string('path')))
            .map(
              (f) => {
                'name': f.name,
                'path': f.path,
                'directory': f.directory,
                'size': f.size,
              },
            )
            .toList();
      case 'files.readText':
        _connection(a);
        return controller.files.readText(string('path'));
      case 'files.readBytes':
        _connection(a);
        final files = controller.files;
        if (files is! ResearchBinaryFiles) {
          throw const BridgeFailure('unsupported', '不支持二进制预览');
        }
        return base64Encode(
          await (files as ResearchBinaryFiles).readBytes(
            string('path'),
            maxBytes: (a['maxBytes'] as int).clamp(1, 8 * 1024 * 1024),
          ),
        );
      case 'files.saveText':
        _connection(a);
        final files = controller.files;
        await files.saveText(
          string('path'),
          a['content'] as String,
          original: a['original'] as String,
        );
        return {
          'recoveryPath': files is ResearchRecoveryFiles
              ? (files as ResearchRecoveryFiles).recoveryPathFor(string('path'))
              : null,
        };
      case 'files.mkdir':
        _connection(a);
        await controller.files.mkdir(string('path'));
      case 'files.upload':
      case 'files.download':
        _connection(a);
        final id = string('transferId');
        if (_transfers.containsKey(id) || _transfers.length >= 32) {
          throw const BridgeFailure('busy', '文件传输数量已达上限');
        }
        final transfer = _OwnedTransfer(scope);
        _transfers[id] = transfer;
        void progress(int count, int total) {
          transfer.count = count;
          transfer.total = total;
        }
        try {
          if (operation == 'files.upload') {
            await controller.files.upload(
              string('local'),
              string('remote'),
              token: transfer.token,
              progress: progress,
            );
          } else {
            await controller.files.download(
              string('remote'),
              string('local'),
              token: transfer.token,
              progress: progress,
            );
          }
        } finally {
          transfer.done = true;
          Timer(const Duration(minutes: 1), () => _transfers.remove(id));
        }
      default:
        throw const BridgeFailure('unsupported', '未知远程操作');
    }
    return null;
  }

  _OwnedTerminal _terminal(String id, String scope) {
    final t = _terminals[id];
    if (t == null || t.scope != scope) {
      throw const BridgeFailure('not_found', '交互终端已关闭');
    }
    return t;
  }

  Map<String, Object?> poll(Map<String, dynamic> a, String scope) {
    final id = a['id'] as String?;
    final cursor = a['cursor'] as int? ?? 0,
        generation = a['generation'] as int? ?? -1;
    if (a['kind'] == 'terminal') {
      final t = _terminal(id!, scope);
      return {
        ...t.output.read(cursor, generation),
        'done': t.done,
        'exitCode': t.code,
      };
    }
    if (a['kind'] == 'call') {
      final call = _calls[id];
      if (call == null || call.scope != scope) {
        throw const BridgeFailure('not_found', '远程命令输出已不可用');
      }
      return call.output.read(cursor, generation);
    }
    if (a['kind'] == 'transfer') {
      final t = _transfers[id];
      if (t == null || t.scope != scope) {
        throw const BridgeFailure('not_found', '传输回执已不可用');
      }
      return {'done': t.done, 'count': t.count, 'total': t.total};
    }
    return controller.hostOutput.read(cursor, generation);
  }

  void cancel(String id, String scope) {
    final call = _calls[id];
    if (call?.scope == scope) call!.token.cancel('图形客户端取消操作');
    final transfer = _transfers[id];
    if (transfer?.scope == scope) transfer!.token.cancelled = true;
  }

  Future<void> releaseClient(String scope) async {
    for (final call in _calls.values.where((c) => c.scope == scope)) {
      call.token.cancel('图形客户端断开');
    }
    for (final t in _transfers.values.where((t) => t.scope == scope)) {
      t.token.cancelled = true;
    }
    for (final id in _terminals.keys.toList()) {
      if (_terminals[id]!.scope == scope) {
        await _terminals.remove(id)!.close();
      }
    }
    for (final id in _sessions.keys.toList()) {
      if (_sessions[id]!.scope == scope) {
        await _sessions.remove(id)!.session.close();
      }
    }
    // The shared SSH connection and native agent sessions intentionally survive.
  }
}

class _OwnedTerminal {
  _OwnedTerminal(this.scope, this.terminal) {
    subscription = terminal.output
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          output.add,
          onError: (Object _) {
            done = true;
          },
        );
    terminal.exitCode.then(
      (value) {
        done = true;
        code = value;
      },
      onError: (Object _) {
        done = true;
      },
    );
  }
  final String scope;
  final TerminalConnection terminal;
  final output = HostTerminalOutput();
  late final StreamSubscription<String> subscription;
  bool done = false;
  int? code;
  Future<void> close() async {
    await subscription.cancel();
    await terminal.close();
  }
}

class _OwnedTransfer {
  _OwnedTransfer(this.scope);
  final String scope;
  final token = ResearchTransferToken();
  int count = 0, total = 0;
  bool done = false;
}
