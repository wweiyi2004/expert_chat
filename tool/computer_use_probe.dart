import 'dart:convert';
import 'dart:io';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/computer_use_probe.dart <cua-driver.exe>',
    );
    exitCode = 2;
    return;
  }
  final client = McpClient();
  final connection = GatewayConnection(
    config: const GatewayConfig(enabled: true),
    apiToken: '',
    localProcess: McpProcessConfig(
      command: args.first,
      arguments: const ['mcp', '--direct'],
    ),
    computerUse: true,
  );
  try {
    final server = await client.discover(connection: connection);
    final output = File('build/computer-use-catalog.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'name': server.name,
        'version': server.version,
        'tools': [
          for (final t in server.tools)
            {
              'name': t.name,
              'description': t.description,
              'inputSchema': t.inputSchema,
            },
        ],
      }),
    );
    stdout.writeln(
      '${server.name} ${server.version}: ${server.tools.length} tools; catalog saved to ${output.path}',
    );
    if (server.tools.any((tool) => tool.name == 'check_permissions')) {
      final result = await client.callTool(
        connection: connection,
        name: 'check_permissions',
        arguments: {'prompt': false},
      );
      stdout.writeln(result.text);
    }
    if (args.contains('--prepare-notepad') ||
        args.contains('--inspect-notepad') ||
        args.contains('--smoke-notepad')) {
      final file = File(
        'build/computer-use-smoke/expert-chat-cua-test.txt',
      ).absolute;
      await file.parent.create(recursive: true);
      if (!await file.exists()) {
        await file.writeAsString('Expert Chat desktop test\n');
      }
      if (args.contains('--prepare-notepad') ||
          args.contains('--smoke-notepad')) {
        await Process.start('notepad.exe', [
          file.path,
        ], mode: ProcessStartMode.detached);
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final windows = await client.callTool(
        connection: connection,
        name: 'list_windows',
        arguments: {},
      );
      final raw = windows.structuredContent;
      // Filter in-process so unrelated window titles never enter the report.
      final targets = <String, Map<String, dynamic>>{};
      void filter(Object? value) {
        if (value is Map) {
          if (value['title'] is String &&
              (value['title'] as String).contains('expert-chat-cua-test') &&
              value['window_id'] is int) {
            targets['${value['pid']}:${value['window_id']}'] =
                Map<String, dynamic>.from(value);
          }
          for (final item in value.values) {
            filter(item);
          }
        }
        if (value is List) {
          for (final item in value) {
            filter(item);
          }
        }
      }

      filter(raw);
      await File(
        'build/computer-use-smoke/windows.json',
      ).writeAsString(jsonEncode(targets.values.toList()));
      if (targets.length != 1) {
        throw StateError(
          'Expected exactly one test window, found ${targets.length}',
        );
      }
      final target = targets.values.single;
      final state = await client.callTool(
        connection: connection,
        name: 'get_window_state',
        arguments: {
          'pid': target['pid'],
          'window_id': target['window_id'],
          'include_screenshot': false,
        },
      );
      await File(
        'build/computer-use-smoke/snapshot.json',
      ).writeAsString(jsonEncode(state.structuredContent));
      stdout.writeln(
        'Test window observed: ${state.structuredContent['element_count']} UIA elements',
      );
      if (args.contains('--smoke-notepad')) {
        final elements = (state.structuredContent['elements'] as List)
            .whereType<Map>();
        final editor = elements.singleWhere(
          (e) =>
              e['role'] == 'Document' &&
              '${e['value']}'.startsWith('Expert Chat'),
        );
        Future<Map<String, dynamic>> desktopPosition() async {
          final result = await Process.run('python', [
            '-c',
            'import ctypes,json; from ctypes import wintypes; u=ctypes.windll.user32; u.GetForegroundWindow.restype=wintypes.HWND; p=wintypes.POINT(); u.GetCursorPos(ctypes.byref(p)); print(json.dumps({"foreground":u.GetForegroundWindow(),"cursor":[p.x,p.y]}))',
          ]);
          if (result.exitCode != 0) {
            throw StateError('Could not read desktop position');
          }
          return Map<String, dynamic>.from(
            jsonDecode(result.stdout as String) as Map,
          );
        }

        final sentinel = await Process.start('python', [
          File('tool/desktop_focus_fixture.py').absolute.path,
        ]);
        await sentinel.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        try {
          final before = await desktopPosition();
          final text =
              'Expert Chat Computer Use 验证成功 ${DateTime.now().toIso8601String()}';
          final updated = await client.callTool(
            connection: connection,
            name: 'set_value',
            arguments: {
              'pid': target['pid'],
              'window_id': target['window_id'],
              'element_token': editor['element_token'],
              'value': text,
            },
          );
          final after = await desktopPosition();
          final changed = (updated.structuredContent['elements'] as List)
              .whereType<Map>()
              .any(
                (e) =>
                    e['role'] == 'Document' && '${e['value']}'.contains(text),
              );
          if (!changed) {
            throw StateError('UIA readback did not contain test text');
          }
          var saveError = '';
          try {
            await client.callTool(
              connection: connection,
              name: 'hotkey',
              arguments: {
                'pid': target['pid'],
                'window_id': target['window_id'],
                'keys': ['ctrl', 's'],
                'delivery_mode': 'background',
              },
            );
          } catch (error) {
            saveError = '$error';
            // The driver refused the shortcut before dispatch. Resolve the menu
            // from fresh UIA observations instead of replaying the shortcut.
            final fresh = await client.callTool(
              connection: connection,
              name: 'get_window_state',
              arguments: {
                'pid': target['pid'],
                'window_id': target['window_id'],
                'include_screenshot': false,
              },
            );
            final menu = (fresh.structuredContent['elements'] as List)
                .whereType<Map>()
                .singleWhere(
                  (e) =>
                      e['role'] == 'MenuItem' &&
                      {'文件', 'File'}.contains(e['label']),
                );
            final opened = await client.callTool(
              connection: connection,
              name: 'click',
              arguments: {
                'pid': target['pid'],
                'window_id': target['window_id'],
                'element_token': menu['element_token'],
              },
            );
            final save = (opened.structuredContent['elements'] as List)
                .whereType<Map>()
                .where(
                  (e) =>
                      e['role'] == 'MenuItem' &&
                      RegExp(
                        r'^(保存|Save)(\s|\(|$)',
                      ).hasMatch('${e['label']}') &&
                      !'${e['label']}'.contains('另存'),
                )
                .toList();
            if (save.length != 1) {
              stdout.writeln(
                'SAVE_MENU: ${jsonEncode((opened.structuredContent['elements'] as List).whereType<Map>().where((e) => e['role'] == 'MenuItem').map((e) => {'label': e['label'], 'element_token': e['element_token']}).toList())}',
              );
            } else {
              await client.callTool(
                connection: connection,
                name: 'click',
                arguments: {
                  'pid': target['pid'],
                  'window_id': target['window_id'],
                  'element_token': save.single['element_token'],
                },
              );
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final persisted = (await file.readAsString()).contains(text);
          final finished = await desktopPosition();
          final report = {
            'driver': '0.28.0',
            'uia_write_readback': changed,
            'saved_to_disk': persisted,
            'started_in_background':
                before['foreground'] != target['window_id'],
            'foreground_preserved': before['foreground'] == after['foreground'],
            'cursor_preserved':
                jsonEncode(before['cursor']) == jsonEncode(after['cursor']),
            'foreground_preserved_through_save':
                before['foreground'] == finished['foreground'],
            'cursor_preserved_through_save':
                jsonEncode(before['cursor']) == jsonEncode(finished['cursor']),
            'save_error': saveError,
            'output': file.path,
          };
          await File(
            'build/computer-use-smoke/result.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
          stdout.writeln(jsonEncode(report));
          if (!persisted) exitCode = 1;
        } finally {
          sentinel.kill();
        }
      }
      if (args.contains('--interactive')) {
        stdout.writeln(
          'READY: read-only snapshot complete; enter one JSON tool call or exit.',
        );
        await for (final line
            in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
          if (line.trim() == 'exit') break;
          try {
            final command = jsonDecode(line) as Map;
            final response = await client.callTool(
              connection: connection,
              name: command['name'] as String,
              arguments: {
                'pid': target['pid'],
                'window_id': target['window_id'],
                ...Map<String, dynamic>.from(
                  command['arguments'] as Map? ?? {},
                ),
              },
            );
            await File(
              'build/computer-use-smoke/snapshot.json',
            ).writeAsString(jsonEncode(response.structuredContent));
            stdout.writeln(response.text);
            stdout.writeln(
              'FILE_CONTENT: ${jsonEncode(await file.readAsString())}',
            );
          } catch (error) {
            stdout.writeln('TOOL_ERROR: $error');
          }
        }
      }
    }
  } finally {
    await client.close();
  }
}
