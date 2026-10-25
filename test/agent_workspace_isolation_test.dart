import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:expert_chat/domain/desktop/agent_workspace_isolation.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/domain/desktop/workspace_host_io.dart';
import 'package:expert_chat/domain/desktop/workspace_tools.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  if (!const bool.fromEnvironment('DESKTOP_WORKSPACE_NATIVE_TEST')) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'dirty tracked binary/untracked baseline isolates and integrates only unchanged parent versions',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final temporary = await Directory.systemTemp.createTemp(
        'expert-isolation-fixture-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final project = await Directory(
        p.join(temporary.path, "project 中文 '"),
      ).create();
      Future<void> git(List<String> args) async {
        final result = await Process.run(
          'git',
          args,
          workingDirectory: project.path,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await git(['init']);
      await File(
        p.join(project.path, 'file.txt'),
      ).writeAsString('committed baseline\n');
      await File(p.join(project.path, 'data.bin')).writeAsBytes([0, 1, 255, 3]);
      await File(p.join(project.path, '.gitignore')).writeAsString('.env\n');
      await git(['add', '.']);
      await git([
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'commit',
        '-m',
        'baseline',
      ]);
      await File(
        p.join(project.path, 'file.txt'),
      ).writeAsString('dirty user baseline\n');
      await File(
        p.join(project.path, 'data.bin'),
      ).writeAsBytes([0, 5, 255, 8, 9]);
      await Directory(p.join(project.path, 'notes')).create();
      await File(
        p.join(project.path, 'notes', '新 文件.bin'),
      ).writeAsBytes([9, 8, 7]);
      await File(
        p.join(project.path, '.env'),
      ).writeAsString('ignored fixture secret');
      final host = CliDesktopWorkspaceHost(
        executable: p.absolute(
          const String.fromEnvironment(
            'DESKTOP_WORKSPACE_TEST_EXECUTABLE',
            defaultValue: 'next/target/debug/expert-desktop.exe',
          ),
        ),
        dataDirectory: p.join(temporary.path, 'authority'),
      );
      await host.add(
        id: 'fixture',
        name: 'Fixture',
        path: project.path,
        access: WorkspaceAccess.readWrite,
      );
      final token = CancelToken();
      final parent = await WorkspaceToolSession.open(host, 'fixture', token);
      addTearDown(parent.close);
      final isolation = await AgentWorkspaceIsolation.create(
        parent: parent,
        host: host,
        id: 'fixture-child',
        token: token,
        approve: (_) async => true,
      );
      expect(
        await host.list(),
        hasLength(1),
        reason: 'No independent clone grant may survive parent revocation',
      );
      final childRoot = p.join(
        project.path,
        '.expert-agent-worktrees',
        'fixture-child',
      );
      expect(
        await File(p.join(childRoot, 'file.txt')).readAsString(),
        'dirty user baseline\n',
      );
      expect(await File(p.join(childRoot, 'data.bin')).readAsBytes(), [
        0,
        5,
        255,
        8,
        9,
      ]);
      expect(await File(p.join(childRoot, 'notes', '新 文件.bin')).readAsBytes(), [
        9,
        8,
        7,
      ]);
      expect(await File(p.join(childRoot, '.env')).exists(), isFalse);
      final recoveredIsolation = await AgentWorkspaceIsolation.restore(
        parent: parent,
        host: host,
        metadata: isolation.recoveryMetadata,
        token: token,
      );
      expect(recoveredIsolation.baseline, isolation.baseline);
      expect(
        recoveredIsolation.baselineIdentities,
        isolation.baselineIdentities,
      );
      final child = await isolation.open(token);
      addTearDown(child.close);
      final read =
          jsonDecode(
                await child.call('coding_read_file', {
                  'scope': 'root',
                  'path': 'file.txt',
                }, token),
              )
              as Map;
      expect(read['path'], 'file.txt');
      final receipt =
          jsonDecode(
                await child.call('coding_write_file', {
                  'scope': 'root',
                  'path': 'file.txt',
                  'content': 'child result\n',
                  'expected_sha256': read['sha256'],
                }, token),
              )
              as Map;
      expect(
        await File(p.join(project.path, 'file.txt')).readAsString(),
        'dirty user baseline\n',
      );
      await File(
        p.join(project.path, 'file.txt'),
      ).writeAsString('human edits during child work\n');
      await expectLater(
        isolation.integrateFile('file.txt', receipt['sha256'] as String, token),
        throwsA(
          predicate((error) => '$error'.contains('Copy destination changed')),
        ),
      );
      expect(
        await File(p.join(project.path, 'file.txt')).readAsString(),
        'human edits during child work\n',
      );
      // Binary integration is a host copy with source and parent revisions,
      // never an attempted UTF-8 round trip.
      await File(p.join(childRoot, 'data.bin')).writeAsBytes([0, 255, 9, 8]);
      final binaryManifest =
          jsonDecode(
                await child.call('coding_artifact_manifest', {
                  'scope': 'root',
                  'path': 'data.bin',
                }, token),
              )
              as Map;
      final binaryResult = await isolation.integrateFile(
        'data.bin',
        binaryManifest['sha256'] as String,
        token,
      );
      expect(binaryResult.binary, isTrue);
      expect(binaryResult.after, isNull);
      expect(await File(p.join(project.path, 'data.bin')).readAsBytes(), [
        0,
        255,
        9,
        8,
      ]);
      // A deleted child source is explicit, and parent modifications still win.
      await File(p.join(childRoot, 'notes', '新 文件.bin')).delete();
      final deletion = await isolation.integrateFile(
        'notes/新 文件.bin',
        'deleted',
        token,
      );
      expect(deletion.deleted, isTrue);
      expect(deletion.after, isNull);
      expect(
        await File(p.join(project.path, 'notes', '新 文件.bin')).exists(),
        isFalse,
      );
      await File(p.join(childRoot, 'file.txt')).delete();
      await expectLater(
        isolation.integrateFile('file.txt', 'deleted', token),
        throwsA(anything),
      );
      expect(
        await File(p.join(project.path, 'file.txt')).readAsString(),
        'human edits during child work\n',
      );
      await host.setScope(
        workspace: 'fixture',
        name: 'root',
        path: project.path,
        access: WorkspaceAccess.readOnly,
      );
      await expectLater(
        child.call('coding_read_file', {
          'scope': 'root',
          'path': 'file.txt',
        }, token),
        throwsA(isA<WorkspaceHostException>()),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
