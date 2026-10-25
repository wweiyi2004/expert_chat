import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

/// No credentials are written until the private directory ACL is established.
class BridgeDiscovery {
  BridgeDiscovery(this.directory);
  final Directory directory;
  File get file => File(p.join(directory.path, 'bridge.json'));
  String? _token;
  static Directory defaultDirectory() {
    final base = Platform.isWindows
        ? Platform.environment['LOCALAPPDATA']
        : Platform.environment['XDG_RUNTIME_DIR'] ??
              Platform.environment['HOME'];
    if (base == null || !p.isAbsolute(base)) throw StateError('缺少安全的用户数据目录');
    return Directory(p.join(base, 'expert-chat', 'tui'));
  }

  Future<void> prepare() async {
    var current = p.absolute(directory.path);
    while (true) {
      if (await FileSystemEntity.isLink(current)) throw StateError('发现路径包含链接');
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    if (Platform.isWindows) {
      final escaped = p.absolute(directory.path).replaceAll("'", "''");
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "\$ErrorActionPreference='Stop'; \$d='$escaped'; "
              "\$c=\$d; while(\$c){ if(Test-Path -LiteralPath \$c){ if((Get-Item -Force -LiteralPath \$c).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse point rejected'} }; \$n=Split-Path -Parent \$c; if(\$n -eq \$c){break}; \$c=\$n }; "
              "[IO.Directory]::CreateDirectory(\$d)|Out-Null; "
              "\$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User; "
              "\$acl=New-Object Security.AccessControl.DirectorySecurity; \$acl.SetAccessRuleProtection(\$true,\$false); "
              "foreach(\$s in @(\$sid,[Security.Principal.SecurityIdentifier]'S-1-5-18')){ \$r=New-Object Security.AccessControl.FileSystemAccessRule(\$s,'FullControl','ContainerInherit,ObjectInherit','None','Allow'); \$acl.AddAccessRule(\$r) }; [IO.Directory]::SetAccessControl(\$d,\$acl); "
              "if(Test-Path -LiteralPath (Join-Path \$d 'bridge.json')){ if((Get-Item -Force -LiteralPath (Join-Path \$d 'bridge.json')).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse file rejected'} }",
        ],
        environment: {...Platform.environment}
          ..removeWhere((key, _) => key.toLowerCase() == 'psmodulepath'),
        includeParentEnvironment: false,
      );
      if (result.exitCode != 0) {
        throw StateError('无法建立桥接目录的当前用户 ACL: ${result.stderr}');
      }
    } else {
      await directory.create(recursive: true);
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) throw StateError('无法保护桥接目录');
    }
    if (await FileSystemEntity.isLink(file.path)) throw StateError('发现文件不能是链接');
  }

  Future<String> publish(int port) async {
    await prepare();
    final random = Random.secure();
    final token = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    // A stale file can have an explicit legacy ACL; replace it, never overwrite.
    if (await file.exists()) await file.delete();
    await file.writeAsString(
      jsonEncode({'v': 1, 'pid': pid, 'port': port, 'token': token}),
      flush: true,
    );
    if (!Platform.isWindows) {
      if ((await Process.run('chmod', ['600', file.path])).exitCode != 0) {
        await file.delete();
        throw StateError('无法保护桥接发现文件');
      }
    }
    _token = token;
    return token;
  }

  Future<void> remove() async {
    try {
      final data = jsonDecode(await file.readAsString()) as Map;
      if (_token != null && data['token'] == _token) await file.delete();
    } on FileSystemException {
      /* Already removed. */
    }
  }
}
