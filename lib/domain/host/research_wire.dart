import '../../state/research_terminal_controller.dart';
import '../../data/research/ssh_profile.dart';
import '../research/research_copilot_service.dart';
import '../research/command_risk.dart';
import 'wire_models.dart';

Map<String, Object?>? encodeProposal(CommandProposal? p) => p == null
    ? null
    : {
        'id': p.id,
        'diagnosis': p.diagnosis,
        'command': p.command,
        'risk': p.risk.name,
        'evidence': p.evidence,
        'impacts': p.impacts,
        'nonImpacts': p.nonImpacts,
        'rollback': p.rollback,
        'rawModelText': p.rawModelText,
        'parseOk': p.parseOk,
      };
CommandProposal? decodeProposal(Object? value) {
  if (value == null) return null;
  final p = wireMap(value);
  return CommandProposal(
    id: p['id'] as String,
    diagnosis: p['diagnosis'] as String,
    command: p['command'] as String,
    risk: CommandRisk.values.byName(p['risk'] as String),
    evidence: (p['evidence'] as List).cast<String>(),
    impacts: (p['impacts'] as List).cast<String>(),
    nonImpacts: (p['nonImpacts'] as List).cast<String>(),
    rollback: p['rollback'] as String?,
    rawModelText: p['rawModelText'] as String?,
    parseOk: p['parseOk'] == true,
  );
}

Map<String, Object?> encodeResearch(ResearchTerminalState s) => {
  'profiles': s.profiles.map((p) => p.toJson()).toList(),
  'activeProfileId': s.activeProfileId,
  'status': s.status.name,
  'statusMessage': s.statusMessage,
  'connectionGeneration': s.connectionGeneration,
  'tmuxSessions': s.tmuxSessions
      .map(
        (t) => {'name': t.name, 'attached': t.attached, 'windows': t.windows},
      )
      .toList(),
  'tmuxError': s.tmuxError,
  'currentTmuxName': s.currentTmuxName,
  'aiContextLines': s.aiContextLines,
  'blockCtrlC': s.blockCtrlC,
  'proposal': encodeProposal(s.proposal),
  'analyzing': s.analyzing,
  'latencyMs': s.latencyMs,
  'cols': s.cols,
  'rows': s.rows,
  'interruptBlockedFlash': s.interruptBlockedFlash,
  'ctrlLatched': s.ctrlLatched,
};
ResearchTerminalState decodeResearch(Object? value) {
  final s = wireMap(value);
  if (s.isEmpty) return const ResearchTerminalState();
  return ResearchTerminalState(
    profiles: wireRows(
      s['profiles'],
    ).map(SshProfile.fromJson).whereType<SshProfile>().toList(),
    activeProfileId: s['activeProfileId'] as String?,
    status: ResearchConnectionStatus.values.byName(s['status'] as String),
    statusMessage: s['statusMessage'] as String,
    connectionGeneration: s['connectionGeneration'] as int,
    tmuxSessions: wireRows(s['tmuxSessions'])
        .map(
          (t) => TmuxSessionInfo(
            name: t['name'] as String,
            attached: t['attached'] as int,
            windows: t['windows'] as int,
          ),
        )
        .toList(),
    tmuxError: s['tmuxError'] as String?,
    currentTmuxName: s['currentTmuxName'] as String?,
    aiContextLines: s['aiContextLines'] as int,
    blockCtrlC: s['blockCtrlC'] == true,
    proposal: decodeProposal(s['proposal']),
    analyzing: s['analyzing'] == true,
    latencyMs: s['latencyMs'] as int?,
    cols: s['cols'] as int,
    rows: s['rows'] as int,
    interruptBlockedFlash: s['interruptBlockedFlash'] == true,
    ctrlLatched: s['ctrlLatched'] == true,
  );
}
