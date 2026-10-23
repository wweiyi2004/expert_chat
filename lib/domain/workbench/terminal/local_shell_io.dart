import 'dart:io';
import 'package:path/path.dart' as p;

class LocalShell {
  const LocalShell(this.executable, this.arguments, this.label);
  final String executable, label;
  final List<String> arguments;
}

LocalShell resolveLocalShell() {
  if (!Platform.isWindows) {
    final shell = Platform.environment['SHELL'] ?? '/bin/sh';
    return LocalShell(shell, const ['-l'], p.basename(shell));
  }
  String? env(String name) {
    for (final entry in Platform.environment.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return null;
  }

  final candidates = <String>[
    for (final directory in (env('PATH') ?? '').split(';'))
      if (directory.trim().isNotEmpty)
        p.join(directory.trim().replaceAll('"', ''), 'pwsh.exe'),
    if (env('ProgramFiles') case final directory?)
      p.join(directory, 'PowerShell', '7', 'pwsh.exe'),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return LocalShell(candidate, const ['-NoLogo'], 'PowerShell');
    }
  }
  // Microsoft Store execution aliases may be launchable even when Dart's
  // File.exists reports false for their special reparse points.
  try {
    final located = Process.runSync(
      p.join(env('SystemRoot') ?? r'C:\Windows', 'System32', 'where.exe'),
      const ['pwsh.exe'],
      runInShell: false,
    );
    if (located.exitCode == 0) {
      for (final line in located.stdout.toString().split(RegExp(r'[\r\n]+'))) {
        final path = line.trim();
        if (p.isAbsolute(path) &&
            p.basename(path).toLowerCase() == 'pwsh.exe') {
          return LocalShell(path, const ['-NoLogo'], 'PowerShell');
        }
      }
    }
  } on ProcessException {
    // Standard Windows PowerShell remains available without an installed pwsh.
  }
  final fallback = p.join(
    env('SystemRoot') ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
  if (File(fallback).existsSync()) {
    return LocalShell(fallback, const ['-NoLogo'], 'Windows PowerShell');
  }
  throw StateError('未找到 PowerShell，请安装 PowerShell 7 后重新打开终端。');
}
