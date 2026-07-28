/// Local command risk labels. Model risk is advisory; final risk is
/// max(model, local).
enum CommandRisk {
  low,
  medium,
  high,
  blocked;

  String get label => switch (this) {
    CommandRisk.low => '低',
    CommandRisk.medium => '中',
    CommandRisk.high => '高',
    CommandRisk.blocked => '禁止',
  };

  int get rank => index;

  static CommandRisk max(CommandRisk a, CommandRisk b) =>
      a.rank >= b.rank ? a : b;

  static CommandRisk? tryParse(String? raw) {
    if (raw == null) return null;
    final t = raw.trim().toLowerCase();
    for (final v in CommandRisk.values) {
      if (v.name == t) return v;
    }
    // Chinese / loose labels from models
    if (t.contains('block') || t.contains('禁止') || t.contains('critical')) {
      return CommandRisk.blocked;
    }
    if (t.contains('high') || t.contains('高')) return CommandRisk.high;
    if (t.contains('med') || t.contains('中')) return CommandRisk.medium;
    if (t.contains('low') || t.contains('低')) return CommandRisk.low;
    return null;
  }
}

class LocalRiskResult {
  const LocalRiskResult({required this.risk, required this.reasons});

  final CommandRisk risk;
  final List<String> reasons;
}

/// Deterministic local classifier — never trust the model alone.
class CommandRiskClassifier {
  const CommandRiskClassifier();

  /// A `>`/`>>` that actually writes a file.
  ///
  /// Whitespace around it is optional (`x >f`, `x>f` write just as well as
  /// `x > f`), so matching on `' > '` misses the dangerous spellings. Excluded:
  /// fd duplication (`2>&1`) and the `>=` / `=>` / `->` operators.
  static final RegExp _writeRedirect = RegExp(r'(?<![=<>-])>>?(?![&=])');

  LocalRiskResult classify(String command) {
    final raw = command;
    final cmd = command.trim();
    final reasons = <String>[];

    if (cmd.isEmpty) {
      return const LocalRiskResult(
        risk: CommandRisk.blocked,
        reasons: ['命令为空'],
      );
    }
    if (cmd.contains('\u0000') ||
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(cmd)) {
      return const LocalRiskResult(
        risk: CommandRisk.blocked,
        reasons: ['包含不可见控制字符'],
      );
    }
    if (cmd.length > 8000) {
      return const LocalRiskResult(
        risk: CommandRisk.blocked,
        reasons: ['命令过长，无法安全解析'],
      );
    }

    var risk = CommandRisk.low;

    void bump(CommandRisk r, String reason) {
      if (r.rank > risk.rank) risk = r;
      if (!reasons.contains(reason)) reasons.add(reason);
    }

    final lower = cmd.toLowerCase();

    // blocked / high destructive patterns
    if (RegExp(
          r'\brm\s+(-[^\s]*f[^\s]*\s+)*(-[^\s]*r|/|~|\*)',
        ).hasMatch(lower) ||
        lower.contains('rm -rf') ||
        lower.contains('rm -fr')) {
      bump(CommandRisk.high, '包含递归强制删除 (rm -rf)');
    }
    if (RegExp(r'\bmkfs\b').hasMatch(lower)) {
      bump(CommandRisk.high, '格式化文件系统 (mkfs)');
    }
    if (RegExp(r'\bdd\s+.*\bof=/dev/').hasMatch(lower) ||
        RegExp(r'\bdd\s+.*\bif=/dev/').hasMatch(lower)) {
      bump(CommandRisk.high, '磁盘 dd 写入设备');
    }
    if (RegExp(r'\b(shutdown|reboot|poweroff|halt)\b').hasMatch(lower)) {
      bump(CommandRisk.high, '关机/重启');
    }
    if (RegExp(r'\bchmod\s+.*-R\b').hasMatch(lower) ||
        RegExp(r'\bchown\s+.*-R\b').hasMatch(lower)) {
      bump(CommandRisk.high, '递归修改权限/所有者');
    }
    if (RegExp(r'curl[^\n|]*\|\s*(ba)?sh').hasMatch(lower) ||
        RegExp(r'wget[^\n|]*\|\s*(ba)?sh').hasMatch(lower)) {
      bump(CommandRisk.high, '管道下载并执行脚本');
    }
    if (RegExp(r'\b(iptables|ufw|firewall-cmd)\b').hasMatch(lower)) {
      bump(CommandRisk.high, '修改防火墙');
    }
    if (RegExp(r'\b(killall|pkill)\b').hasMatch(lower) ||
        RegExp(r'\bkill\s+-9\b').hasMatch(lower)) {
      bump(CommandRisk.medium, '批量/强制结束进程');
    }

    // medium
    if (RegExp(r'\bsudo\b').hasMatch(lower)) {
      bump(CommandRisk.medium, '使用 sudo 提权');
    }
    if (RegExp(
      r'\b(apt|yum|dnf|pacman|pip|npm)\s+(install|remove|upgrade)\b',
    ).hasMatch(lower)) {
      bump(CommandRisk.medium, '安装/卸载软件包');
    }
    if (RegExp(r'\b(sbatch|scancel|scontrol)\b').hasMatch(lower)) {
      bump(CommandRisk.medium, '集群作业提交/取消');
    }
    if (RegExp(r'(^|[;&|])\s*(mv|cp)\s+.*\s+/').hasMatch(lower) &&
        _writeRedirect.hasMatch(raw)) {
      bump(CommandRisk.medium, '可能覆盖文件');
    }
    if (_writeRedirect.hasMatch(raw)) {
      bump(CommandRisk.medium, '重定向写入文件');
    }
    if (RegExp(r'\btee\b').hasMatch(lower)) {
      bump(CommandRisk.medium, '通过 tee 写入文件');
    }

    if (reasons.isEmpty) {
      reasons.add('看起来像只读查询或常规进程启动');
    }
    return LocalRiskResult(risk: risk, reasons: reasons);
  }
}
