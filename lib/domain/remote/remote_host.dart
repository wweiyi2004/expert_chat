import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart' show CancelToken, DioException;
import 'remote_model.dart';
import 'package:crypto/crypto.dart';
import '../tools/math/math_spec.dart';
import 'host_secrets.dart';
import 'remote_policy.dart';

/// A deliberately small execution host. Commands require approval and never replay
/// after a crash. The owner supplies a fixed workspace; it is not a sandbox.
class RemoteHost {
  RemoteHost(
    this.directory,
    this.workspace, {
    this.token,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  String _version(Map<String, dynamic> task) =>
      task['version'] as String? ?? task['updatedAt'] as String? ?? '';
  final Directory directory;
  final Directory workspace;
  String? _boundWorkspace;
  String get _workspacePath => _boundWorkspace ?? workspace.path;
  String _pathIdentity(String value) =>
      Platform.isWindows ? value.toLowerCase() : value;
  Future<String> _scopeRoot() async {
    final resolved = await Directory(_workspacePath).resolveSymbolicLinks();
    if (_pathIdentity(resolved) != _pathIdentity(_workspacePath)) {
      throw StateError(
        'Workspace root changed; restart and reauthorize explicitly',
      );
    }
    return resolved;
  }

  String? token;
  final _retiredCredentials = <String>[];
  late final _secrets = HostSecrets(
    () => [?token, ?modelKey, ?reviewModelKey, ..._retiredCredentials],
  );
  final Map<String, Map<String, dynamic>> tasks = {};
  final Map<String, Process> _processes = {};
  String? _commandTask;
  final _drainingCommands = <String>{};
  DateTime credentialExpiresAt = DateTime.now().toUtc().add(
    const Duration(days: 30),
  );
  HttpServer? _server;
  SecurityContext? tls;
  bool protectedTunnel = false;
  RandomAccessFile? _lock;
  int get port => _server!.port;
  final List<Map<String, dynamic>> events = [];
  int _cursor = 0;
  final _badAuthentication = <String, ({DateTime until, int failures})>{};
  final Map<String, Map<String, dynamic>> automations = {};
  final Map<String, Map<String, dynamic>> environments = {};
  Timer? _automationTimer;
  Future<void>? _activeAutomationScan;
  bool _closing = false;
  bool _scanning = false;
  String? modelUrl;
  String? modelName;
  String? modelKey;
  String modelFormat = 'openAiCompatible';
  int maxRounds = 20;
  int roundCeiling = 200;
  bool allowAutoBudgetExtension = false;
  int maxBudgetReviews = 2;
  int budgetExtensionRounds = 5;
  final allowedPolicies = <String>{'request'};
  String? reviewModelUrl, reviewModelName, reviewModelKey, reviewModelFormat;
  Future<ApprovalVerdict> Function(
    Map<String, dynamic>,
    String,
    String,
    CancelToken,
  )?
  reviewer;
  int commandTimeoutSeconds = 600;
  final _model = RemoteModel();
  final _modelCancels = <String, CancelToken>{};
  Future<String> Function(Map<String, dynamic>)? mathExecutor;
  Map<String, String> get safeToolEnvironment =>
      _secrets.childEnvironment(Platform.environment);
  String get _modelIdentity => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'url': modelUrl,
            'model': modelName,
            'format': modelFormat,
            'account': sha256.convert(utf8.encode(modelKey ?? '')).toString(),
          }),
        ),
      )
      .toString();
  void _assertTaskModel(Map<String, dynamic> task) {
    if (task['kind'] != 'agent') return;
    final binding = task['modelIdentity'];
    if ((binding != null && binding != _modelIdentity) ||
        (binding == null && (task['history'] as List? ?? []).isNotEmpty)) {
      throw StateError('模型、协议或账户配置已改变；原任务不会向新配置发送历史。请恢复原配置，或核验旧操作后新建目标。');
    }
  }

  Future<void> open({bool rotatePairing = false}) async {
    await directory.create(recursive: true);
    if (!await workspace.exists()) {
      throw ArgumentError('Workspace does not exist');
    }
    final privatePath = await directory.resolveSymbolicLinks();
    final workPath = await workspace.resolveSymbolicLinks();
    _boundWorkspace = workPath;
    if (privatePath == workPath ||
        privatePath.startsWith('$workPath${Platform.pathSeparator}') ||
        workPath.startsWith('$privatePath${Platform.pathSeparator}')) {
      throw ArgumentError('Private host state and workspace must not overlap');
    }
    _lock = await File(
      '${directory.path}/host.lock',
    ).open(mode: FileMode.append);
    await _lock!.lock(FileLock.exclusive);
    final binding = File('${directory.path}/workspace-binding');
    if (await binding.exists() &&
        _pathIdentity((await binding.readAsString()).trim()) !=
            _pathIdentity(workPath)) {
      throw StateError(
        'Host journal is bound to another workspace; use a separate private data directory',
      );
    }
    final credential = File('${directory.path}/credential');
    if (rotatePairing) {
      final old = await credential.exists()
          ? (await credential.readAsString()).trim()
          : '';
      if (old.length >= 32) _retiredCredentials.add(old);
      token = base64Url.encode(
        List.generate(32, (_) => Random.secure().nextInt(256)),
      );
      credentialExpiresAt = DateTime.now().toUtc().add(
        const Duration(days: 30),
      );
    }
    token ??= await credential.exists()
        ? (await credential.readAsString()).trim()
        : base64Url.encode(
            List.generate(32, (_) => Random.secure().nextInt(256)),
          );
    if (token!.length < 32 ||
        token!.length > 256 ||
        !RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(token!)) {
      throw StateError(
        'Host credential is invalid; data preserved. Restart with --rotate-pairing to explicitly replace the damaged key',
      );
    }
    await credential.writeAsString(token!, flush: true);
    final expiry = File('${directory.path}/credential-expiry');
    if (await expiry.exists() && !rotatePairing) {
      credentialExpiresAt = DateTime.parse(await expiry.readAsString());
    } else {
      await expiry.writeAsString(
        credentialExpiresAt.toIso8601String(),
        flush: true,
      );
    }
    final checkpoint = File('${directory.path}/checkpoint.json');
    var checkpointCursor = 0;
    if (await checkpoint.exists()) {
      final data = jsonDecode(await checkpoint.readAsString()) as Map;
      checkpointCursor = data['cursor'] as int;
      _cursor = checkpointCursor;
      for (final raw in data['tasks'] as List) {
        final task = Map<String, dynamic>.from(raw as Map);
        tasks[task['id'] as String] = task;
      }
    }
    final journal = File('${directory.path}/events.jsonl');
    if (await journal.exists()) {
      final lines = await journal.readAsLines();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trim().isEmpty) continue;
        try {
          final event = Map<String, dynamic>.from(jsonDecode(lines[i]) as Map);
          final visible = {...event};
          if (visible['task'] is Map) {
            visible['task'] = _publicTask(
              Map<String, dynamic>.from(visible['task'] as Map),
            );
          }
          events.add(visible);
          _cursor = max(_cursor, event['cursor'] as int);
          if (event['task'] != null &&
              (event['cursor'] as int) > checkpointCursor) {
            final task = Map<String, dynamic>.from(event['task'] as Map);
            tasks[task['id'] as String] = task;
          }
        } catch (_) {
          // A damaged final dispatch/submission record may have contained an
          // identity not present in the prefix. Preserve bytes and fail closed.
          throw StateError(
            'Task journal is damaged at record ${i + 1}; data preserved. Restore a reviewed backup before restarting; no operation was replayed.',
          );
        }
      }
      if (events.length > 1000) events.removeRange(0, events.length - 1000);
    }
    for (final task in tasks.values) {
      final saved = task['workspace'];
      if (saved is! String ||
          _pathIdentity(await Directory(saved).resolveSymbolicLinks()) !=
              _pathIdentity(workPath)) {
        throw StateError(
          'Retained task target differs from this workspace; refusing to retarget',
        );
      }
    }
    if (!await binding.exists()) {
      await binding.writeAsString(workPath, flush: true);
    }
    for (final task in tasks.values.toList()) {
      if (task['state'] == 'queued') {
        await _record(
          task,
          'awaitingApproval',
          'Host restarted before queued dispatch; approve again',
        );
      }
      if (task['state'] == 'running' || task['state'] == 'stopping') {
        await _record(
          task,
          'unknown',
          'Host restarted; inspect side effects. This task will not replay.',
        );
      }
    }
    final config = File('${directory.path}/automation.json');
    if (await config.exists()) {
      final data = jsonDecode(await config.readAsString()) as Map;
      for (final item in data['automations'] as List? ?? []) {
        automations[item['id'] as String] = Map<String, dynamic>.from(
          item as Map,
        );
      }
      for (final item in data['environments'] as List? ?? []) {
        environments[item['id'] as String] = Map<String, dynamic>.from(
          item as Map,
        );
      }
    }
    _closing = false;
    _automationTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_closing || _activeAutomationScan != null) return;
      final scan = _scanAutomations();
      _activeAutomationScan = scan;
      unawaited(
        scan.whenComplete(() {
          if (identical(_activeAutomationScan, scan)) {
            _activeAutomationScan = null;
          }
        }),
      );
    });
  }

  Future<void> listen({
    String address = '127.0.0.1',
    int port = 0,
    bool allowNetwork = false,
  }) async {
    final ip = InternetAddress(address);
    if (!ip.isLoopback && !allowNetwork) {
      throw ArgumentError('Network binding requires explicit allowNetwork');
    }
    if (!ip.isLoopback && tls == null && !protectedTunnel) {
      throw ArgumentError(
        'Network listener requires TLS or explicit protectedTunnel',
      );
    }
    _server = tls == null
        ? await HttpServer.bind(ip, port)
        : await HttpServer.bindSecure(ip, port, tls!);
    _server!.listen((request) async {
      try {
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
                'Bearer $token' ||
            DateTime.now().toUtc().isAfter(credentialExpiresAt)) {
          final address =
              request.connectionInfo?.remoteAddress.address ?? 'unknown';
          final now = DateTime.now().toUtc(),
              previous = _badAuthentication[address];
          final failures = previous == null || !now.isBefore(previous.until)
              ? 1
              : min(6, previous.failures + 1);
          if (!_badAuthentication.containsKey(address) &&
              _badAuthentication.length >= 256) {
            _badAuthentication.remove(_badAuthentication.keys.first);
          }
          _badAuthentication[address] = (
            until: failures == 1
                ? now.add(const Duration(minutes: 1))
                : previous!.until,
            failures: failures,
          );
          request.response.statusCode = failures > 5 ? 429 : 401;
          if (failures > 5) {
            request.response.headers.set('Retry-After', '60');
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
          await _respond(request, {
            'error': failures > 5
                ? 'Too many authentication failures; wait before retrying'
                : 'Unauthorized',
          });
          return;
        }
        final parts = request.uri.pathSegments;
        if (request.method == 'GET' && parts.join('/') == 'v1/files') {
          final relative = request.uri.queryParameters['path'] ?? '';
          final root = await _scopeRoot();
          final directoryPath = relative.isEmpty
              ? root
              : await Directory(
                  '$_workspacePath/$relative',
                ).resolveSymbolicLinks();
          if (directoryPath != root &&
              !directoryPath.startsWith('$root${Platform.pathSeparator}')) {
            throw ArgumentError('Directory escapes workspace');
          }
          final entries = <Map<String, dynamic>>[];
          await for (final entry in Directory(
            directoryPath,
          ).list(followLinks: false)) {
            if (entries.length >= 1000) break;
            final stat = await entry.stat();
            entries.add({
              'name': entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
              'directory': entry is Directory,
              'link': entry is Link,
              'size': stat.size,
            });
          }
          await _respond(request, {'entries': entries});
          return;
        }
        if (request.method == 'GET' && parts.join('/') == 'v1/git') {
          final view = request.uri.queryParameters['view'] ?? 'status';
          final arguments = switch (view) {
            'status' => ['status', '--short', '--branch'],
            'log' => [
              'log',
              '--graph',
              '--all',
              '-n',
              '100',
              '--format=%h %p %s',
            ],
            'branches' => ['branch', '-avv'],
            'worktrees' => ['worktree', 'list', '--porcelain'],
            'diff' => ['diff', '--no-ext-diff', '--no-textconv', '--'],
            _ => throw ArgumentError('Unknown Git view'),
          };
          final process = await Process.start('git', [
            '-c',
            'core.fsmonitor=false',
            ...arguments,
          ], workingDirectory: await _scopeRoot());
          final timer = Timer(
            const Duration(seconds: 15),
            () => process.kill(),
          );
          Future<String> bounded(Stream<List<int>> stream) async {
            final output = StringBuffer();
            await for (final chunk in stream.transform(
              const Utf8Decoder(allowMalformed: true),
            )) {
              if (output.length < 64000) {
                output.write(
                  chunk.substring(0, min(chunk.length, 64000 - output.length)),
                );
              } else {
                process.kill();
              }
            }
            return output.toString();
          }

          final outputs = await Future.wait([
            bounded(process.stdout),
            bounded(process.stderr),
          ]);
          final code = await process.exitCode;
          timer.cancel();
          await _respond(request, {
            'exitCode': code,
            'stdout': outputs[0],
            'stderr': outputs[1],
          });
          return;
        }
        if (request.method == 'GET' && parts.join('/') == 'v1/tools') {
          await _respond(request, {'math': mathExecutor != null});
          return;
        }
        if (request.method == 'POST' && parts.join('/') == 'v1/tools/math') {
          final executor = mathExecutor;
          if (executor == null) {
            throw StateError('Host math worker unavailable');
          }
          await _respond(request, {
            'result': await executor(await _body(request)),
          });
          return;
        }
        if (request.method == 'POST' &&
            parts.join('/') == 'v1/pairing/revoke') {
          await rotateCredential();
          await _respond(request, {'revoked': true});
          return;
        }
        if (request.method == 'GET' && parts.join('/') == 'v1/artifact') {
          final file = await _scopedFile(
            request.uri.queryParameters['path'] ?? '',
          );
          if (request.uri.queryParameters['download'] == '1') {
            request.response.headers.contentType = ContentType.binary;
            request.response.headers.set('Cache-Control', 'no-store');
            await request.response.addStream(file.openRead());
            await request.response.close();
            return;
          }
          if (await file.length() > 8 * 1024 * 1024) {
            throw StateError('Artifact exceeds 8 MiB transfer bound');
          }
          final bytes = await file.readAsBytes();
          await _respond(request, {
            'path': request.uri.queryParameters['path'],
            'bytes': base64Encode(bytes),
            'sha256': sha256.convert(bytes).toString(),
          });
          return;
        }
        if (request.method == 'POST' &&
            parts.length == 4 &&
            parts[0] == 'v1' &&
            parts[1] == 'environments' &&
            parts[3] == 'start') {
          final environment = environments[parts[2]];
          if (environment == null) throw ArgumentError('Unknown environment');
          final input = await _body(request);
          await _respond(
            request,
            await submit({
              'id': input['id'],
              'command': environment['startup'],
            }),
          );
          return;
        }
        if (request.method == 'GET' && parts.join('/') == 'v1/automation') {
          await _respond(request, {
            'automations': automations.values.toList(),
            'environments': environments.values.toList(),
            'allowedPolicies': allowedPolicies.toList(),
            'defaultRoundLimit': maxRounds,
            'roundCeiling': roundCeiling,
            'allowAutoBudgetExtension': allowAutoBudgetExtension,
          });
        } else if (request.method == 'POST' &&
            parts.join('/') == 'v1/automation') {
          await configureAutomation(await _body(request));
          await _respond(request, {'ok': true});
        } else if (request.method == 'POST' &&
            parts.length == 3 &&
            parts[0] == 'v1' &&
            parts[1] == 'webhooks') {
          final input = await _body(request);
          await trigger(parts[2], input['eventId'] as String? ?? '');
          await _respond(request, {'ok': true});
        } else if (request.method == 'GET' && parts.join('/') == 'v1/tasks') {
          await _respond(request, {
            'tasks': tasks.values.map(_publicTask).toList(),
            'workspace': _workspacePath,
            'allowedPolicies': allowedPolicies.toList(),
            'defaultRoundLimit': maxRounds,
            'roundCeiling': roundCeiling,
            'allowAutoBudgetExtension': allowAutoBudgetExtension,
          });
        } else if (request.method == 'GET' && parts.join('/') == 'v1/events') {
          final after =
              int.tryParse(request.uri.queryParameters['after'] ?? '0') ?? 0;
          await _respond(request, {
            'events': events
                .where((e) => (e['cursor'] as int) > after)
                .take(500)
                .toList(),
            'historyTruncated':
                events.isNotEmpty &&
                after < (events.first['cursor'] as int) - 1,
          });
        } else if (request.method == 'POST' && parts.join('/') == 'v1/tasks') {
          await _respond(request, await submit(await _body(request)));
        } else if (parts.length == 4 &&
            parts[0] == 'v1' &&
            parts[1] == 'tasks' &&
            request.method == 'POST') {
          final task = tasks[parts[2]];
          if (task == null) throw ArgumentError('Unknown task');
          if (parts[3] == 'approve') {
            final input = await _body(request);
            if (input['version'] is! String) {
              throw ArgumentError('Reviewed step version required');
            }
            await approve(
              parts[2],
              expectedVersion: input['version'] as String,
            );
          } else if (parts[3] == 'stop') {
            await stop(parts[2]);
          } else if (parts[3] == 'budget') {
            final input = await _body(request);
            if (input['version'] is! String ||
                input['additionalRounds'] is! int) {
              throw ArgumentError('Version and additionalRounds required');
            }
            await extendBudget(
              parts[2],
              input['additionalRounds'] as int,
              expectedVersion: input['version'] as String,
            );
          } else if (parts[3] == 'resolve') {
            final input = await _body(request);
            await _serial(() async {
              if (task['state'] != 'unknown' ||
                  input['version'] != _version(task)) {
                throw StateError('Task is not the reviewed unknown version');
              }
              final state = input['state'];
              final note = input['note'];
              if (!['completed', 'failed', 'stopped'].contains(state) ||
                  note is! String ||
                  note.trim().isEmpty ||
                  note.length > 4000) {
                throw ArgumentError('Verified outcome and note required');
              }
              task['verificationNote'] = note;
              await _record(
                task,
                state as String,
                'Human verified unknown outcome; no operation replayed',
              );
              await _drainQueue();
            });
          } else {
            throw ArgumentError('Unknown action');
          }
          await _respond(request, task);
        } else {
          request.response.statusCode = 404;
          await _respond(request, {'error': 'Unknown route'});
        }
      } catch (error) {
        // A disconnected UI must not tear down the execution host, including
        // when a streamed artifact already sent its response headers.
        try {
          request.response.statusCode = 400;
          await _respond(request, {'error': error.toString()});
        } catch (_) {}
      }
    });
  }

  Future<void> _mutations = Future.value();
  Map<String, dynamic> _publicTask(Map<String, dynamic> task) =>
      Map<String, dynamic>.from(
        _secrets.sanitize({...task}..remove('history')) as Map,
      );
  Future<void> rotateCredential() => _serial(() async {
    final next = base64Url.encode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final expires = DateTime.now().toUtc().add(const Duration(days: 30));
    await File('${directory.path}/credential').writeAsString(next, flush: true);
    await File(
      '${directory.path}/credential-expiry',
    ).writeAsString(expires.toIso8601String(), flush: true);
    if (token != null) _retiredCredentials.add(token!);
    if (_retiredCredentials.length > 8) _retiredCredentials.removeAt(0);
    token = next;
    credentialExpiresAt = expires;
  });
  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _mutations.then((_) => work());
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<Map<String, dynamic>> submit(Map<String, dynamic> input) async {
    var created = false;
    final task = await _serial(() async {
      created = !tasks.containsKey(input['id']);
      return _submit(input);
    });
    if (created && task['policy'] != 'request') {
      unawaited(_startAuthorizedTask(task));
    }
    return task;
  }

  Future<Map<String, dynamic>> _submit(Map<String, dynamic> input) async {
    if (jsonEncode(input) != jsonEncode(_secrets.sanitize(input))) {
      throw ArgumentError(
        'Task contains a host credential; remove it before submission',
      );
    }
    final id = input['id'];
    final command = input['command'] ?? input['goal'];
    final policy = input['policy'] ?? 'request';
    final roundLimit = input['roundLimit'] ?? maxRounds;
    final submittedOptions = {
      'policy': policy,
      'roundLimit': input['roundLimit'],
      'autoBudgetExtension': input['autoBudgetExtension'] == true,
    };
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id) ||
        command is! String ||
        command.trim().isEmpty ||
        command.length > 32000) {
      throw ArgumentError('Valid id and command required');
    }
    final existing = tasks[id];
    if (existing != null) {
      if (existing['command'] != command ||
          existing['kind'] != (input['goal'] != null ? 'agent' : 'command') ||
          (existing['policy'] ?? 'request') != policy ||
          jsonEncode(
                existing['submittedOptions'] ??
                    {
                      'policy': existing['policy'] ?? 'request',
                      'roundLimit': null,
                      'autoBudgetExtension': false,
                    },
              ) !=
              jsonEncode(submittedOptions) ||
          existing['workspace'] != _workspacePath) {
        throw StateError('Submission id already has different content');
      }
      return existing;
    }
    if (!allowedPolicies.contains(policy) ||
        !['request', 'assisted', 'full'].contains(policy)) {
      throw ArgumentError('Host has not authorized this execution policy');
    }
    if (roundLimit is! int || roundLimit < 1 || roundLimit > roundCeiling) {
      throw ArgumentError('Round limit exceeds host ceiling');
    }
    if (input['autoBudgetExtension'] == true && !allowAutoBudgetExtension) {
      throw ArgumentError('Host has not authorized automatic round extension');
    }
    final task = <String, dynamic>{
      'id': id,
      'command': command,
      'kind': input['goal'] != null ? 'agent' : 'command',
      'workspace': _workspacePath,
      'policy': policy,
      'submittedOptions': submittedOptions,
      'roundLimit': roundLimit,
      'autoBudgetExtension': input['autoBudgetExtension'] == true,
      'createdAt': _clock().toUtc().toIso8601String(),
    };
    await _record(
      task,
      'awaitingApproval',
      'Task policy: $policy. Runs with host account privileges; workspace is not a sandbox.',
    );
    tasks[id] = task;
    return task;
  }

  Future<void> _startAuthorizedTask(Map<String, dynamic> task) async {
    try {
      if (task['kind'] == 'agent') {
        await approve(task['id'] as String, expectedVersion: _version(task));
      } else {
        await _autoCommand(task);
      }
    } catch (_) {
      /* A concurrent explicit stop/approval owns the newer state. */
    }
  }

  Future<ApprovalVerdict> _reviewTask(
    Map<String, dynamic> task,
    String command,
    String purpose,
    CancelToken cancel,
  ) async {
    try {
      final custom = reviewer;
      final verdict = custom != null
          ? await custom(
              Map<String, dynamic>.from(_secrets.sanitize(task) as Map),
              command,
              purpose,
              cancel,
            )
          : await _model.review(
              url:
                  reviewModelUrl ??
                  modelUrl ??
                  (throw StateError('Reviewer not configured')),
              model:
                  reviewModelName ??
                  modelName ??
                  (throw StateError('Reviewer model not configured')),
              key: reviewModelKey ?? modelKey ?? '',
              format: reviewModelFormat ?? modelFormat,
              goal: (task['command'] as String).substring(
                0,
                min(4096, (task['command'] as String).length),
              ),
              command: command,
              workspace: _workspacePath,
              cancel: cancel,
              purpose: purpose,
            );
      return ApprovalVerdict.fromJson({
        'verdict': verdict.verdict,
        'reason': _secrets.redact(verdict.reason),
      });
    } catch (_) {
      return const ApprovalVerdict('unknown', '审查不可用、超时或格式不完整，等待人工批准');
    }
  }

  Future<void> _autoCommand(
    Map<String, dynamic> task, {
    CancelToken? inheritedCancel,
  }) async {
    final policy = task['policy'] as String? ?? 'request';
    if (policy == 'request' ||
        !allowedPolicies.contains(policy) ||
        task['state'] != 'awaitingApproval') {
      return;
    }
    final id = task['id'] as String;
    final cancel = inheritedCancel ?? CancelToken();
    if (inheritedCancel == null) _modelCancels[id] = cancel;
    final version = _version(task);
    final command = (task['pendingCommand'] ?? task['command']) as String;
    try {
      final decision = policy == 'full'
          ? const ApprovalVerdict('approve', '用户选择了宿主明确允许的完全访问模式')
          : await _reviewTask(task, command, 'command', cancel);
      await _serial(() async {
        if (cancel.isCancelled ||
            !allowedPolicies.contains(policy) ||
            task['state'] != 'awaitingApproval' ||
            _version(task) != version ||
            (task['pendingCommand'] ?? task['command']) != command) {
          return;
        }
        task['approvalReview'] = {
          'policy': policy,
          'verdict': decision.verdict,
          'reason': decision.reason,
          'reviewedVersion': version,
          'commandHash': sha256.convert(utf8.encode(command)).toString(),
        };
        await _record(
          task,
          'awaitingApproval',
          '执行策略 $policy · ${decision.verdict}：${decision.reason}',
        );
        if (decision.approved) {
          await _approve(id, expectedVersion: _version(task));
        }
      });
    } finally {
      if (inheritedCancel == null && identical(_modelCancels[id], cancel)) {
        _modelCancels.remove(id);
      }
    }
  }

  Future<bool> _ensureBudget(
    Map<String, dynamic> task,
    CancelToken cancel,
  ) async {
    final used = task['round'] as int? ?? 0;
    final limit = task['roundLimit'] as int? ?? maxRounds;
    _assertTaskModel(task);
    if (used < limit) return true;
    final reviews = task['budgetReviews'] as int? ?? 0;
    if (allowAutoBudgetExtension &&
        task['autoBudgetExtension'] == true &&
        reviews < maxBudgetReviews &&
        limit < roundCeiling) {
      task['budgetReviews'] = reviews + 1;
      await _record(task, 'running', '达到轮次边界，开始有界续轮审查');
      final extra = min(budgetExtensionRounds, roundCeiling - limit);
      final history = task['history'] as List? ?? [];
      final progress = history.isEmpty ? '' : jsonEncode(history.last);
      final decision = await _reviewTask(
        task,
        jsonEncode({
          'additionalRounds': extra,
          'used': used,
          'limit': limit,
          'hostCeiling': roundCeiling,
          'latestProgress': progress.substring(0, min(3000, progress.length)),
          'completedToolsMustNotReplay': true,
        }),
        'budget',
        cancel,
      );
      return _serial(() async {
        if (cancel.isCancelled || task['state'] != 'running') return false;
        task['budgetReview'] = {
          'verdict': decision.verdict,
          'reason': decision.reason,
          'review': reviews + 1,
          'requestedRounds': extra,
        };
        if (decision.approved &&
            allowAutoBudgetExtension &&
            limit + extra <= roundCeiling &&
            (task['roundLimit'] as int? ?? maxRounds) == limit) {
          task['roundLimit'] = limit + extra;
          await _record(task, 'running', '续轮审查批准 +$extra：${decision.reason}');
          return true;
        }
        await _record(
          task,
          'waiting_budget',
          '续轮审查未批准：${decision.reason}；等待人工追加轮次或停止',
        );
        return false;
      });
    }
    await _serial(() async {
      if (task['state'] == 'running' && !cancel.isCancelled) {
        await _record(task, 'waiting_budget', '已达到 $limit 轮；保留历史，等待人工追加轮次或停止');
      }
    });
    return false;
  }

  Future<void> extendBudget(
    String id,
    int additionalRounds, {
    required String expectedVersion,
  }) => _serial(() async {
    final task = tasks[id] ?? (throw ArgumentError('Unknown task'));
    if (task['state'] != 'waiting_budget' ||
        _version(task) != expectedVersion) {
      throw StateError('Task is not the reviewed budget boundary');
    }
    _assertTaskModel(task);
    final limit = task['roundLimit'] as int? ?? maxRounds;
    if (additionalRounds < 1 ||
        additionalRounds > 1000 ||
        limit + additionalRounds > roundCeiling) {
      throw ArgumentError('Additional rounds exceed host ceiling');
    }
    task['roundLimit'] = limit + additionalRounds;
    await _record(
      task,
      'awaitingApproval',
      '用户追加 $additionalRounds 轮；从已记录历史继续，不重放完成的工具',
    );
    await _approve(id, expectedVersion: _version(task));
  });

  Future<void> approve(String id, {String? expectedVersion}) =>
      _serial(() => _approve(id, expectedVersion: expectedVersion));
  Future<void> _approve(String id, {String? expectedVersion}) async {
    final task = tasks[id]!;
    if (expectedVersion != null && expectedVersion != _version(task)) {
      throw StateError(
        'Approval is stale; refresh and review the current step',
      );
    }
    if (task['state'] != 'awaitingApproval') {
      throw StateError('Task is not awaiting approval');
    }
    _assertTaskModel(task);
    if (task['kind'] == 'agent' && task['pendingCommand'] == null) {
      await _record(
        task,
        'running',
        'Approved model execution; request boundary persisted',
      );
      unawaited(_agentStep(task));
      return;
    }
    if (_commandTask != null || _hasUnknownCommand) {
      await _record(
        task,
        'queued',
        'Command approved; waiting for this fixed workspace command lease',
      );
      return;
    }
    await _record(task, 'running', 'Approved; dispatch boundary persisted');
    _commandTask = id;
    // Mark running before spawning so a failed/crashed dispatch is never replayed.
    try {
      final process = await Process.start(
        Platform.isWindows ? 'powershell.exe' : '/bin/sh',
        Platform.isWindows
            ? [
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                "[Console]::OutputEncoding = [Text.UTF8Encoding]::new(\$false); \$OutputEncoding = [Console]::OutputEncoding; ${task['pendingCommand'] ?? task['command']}",
              ]
            : ['-c', (task['pendingCommand'] ?? task['command']) as String],
        workingDirectory: await _scopeRoot(),
        includeParentEnvironment: false,
        environment: {
          ..._secrets.childEnvironment(Platform.environment),
          'PYTHONIOENCODING': 'utf-8',
          'PYTHONUTF8': '1',
        },
      );
      _processes[id] = process;
      task['pid'] = process.pid;
      final capturedOutput = StringBuffer();
      var outputBytes = 0;
      final timer = Timer(Duration(seconds: commandTimeoutSeconds), () {
        unawaited(stop(id));
      });
      final readers = <StreamSubscription<String>>[];
      final readerDone = <Completer<void>>[];
      final writes = <Future<int>>[];
      for (final entry in [process.stdout, process.stderr].asMap().entries) {
        final done = Completer<void>();
        readerDone.add(done);
        readers.add(
          _secrets
              .protect(
                entry.value.transform(const Utf8Decoder(allowMalformed: true)),
              )
              .listen(
                (chunk) {
                  if (outputBytes >= 256000) return;
                  final text = chunk.substring(
                    0,
                    min(chunk.length, 256000 - outputBytes),
                  );
                  outputBytes += text.length;
                  capturedOutput.write(text);
                  writes.add(
                    _append({
                      'taskId': id,
                      'kind': entry.key == 0 ? 'stdout' : 'stderr',
                      'text': text,
                    }),
                  );
                },
                onDone: () {
                  if (!done.isCompleted) done.complete();
                },
                onError: (Object error, StackTrace stack) {
                  if (!done.isCompleted) done.completeError(error, stack);
                },
              ),
        );
      }
      unawaited(() async {
        final code = await process.exitCode;
        timer.cancel();
        _processes.remove(
          id,
        ); // Never target a recycled PID after its root exited.
        _drainingCommands.add(id);
        var detachedOutput = false;
        try {
          await Future.wait(
            readerDone.map((done) => done.future),
          ).timeout(const Duration(seconds: 2));
        } on TimeoutException {
          detachedOutput = true;
        } finally {
          for (final reader in readers) {
            await reader.cancel();
          }
        }
        await Future.wait(writes);
        _drainingCommands.remove(id);
        if (detachedOutput || task['state'] == 'unknown') {
          task['exitCode'] = code;
          await _record(
            task,
            'unknown',
            'Root exited but inherited output pipes remain open; inspect child processes before resolving. No recycled PID was targeted.',
          );
          _commandTask = null;
          return;
        }
        _commandTask = null;
        unawaited(_serial(_drainQueue));
        task['exitCode'] = code;
        task['outputTruncated'] = outputBytes >= 256000;
        if (task['kind'] == 'agent' && task['state'] != 'stopping') {
          final history = task['history'] as List<dynamic>;
          history.add({
            'role': 'tool',
            'tool_call_id': task['pendingToolId'],
            'content': jsonEncode({
              'exitCode': code,
              'outputTruncated': outputBytes >= 256000,
              'contextOutputTruncated': capturedOutput.length > 24000,
              'output': capturedOutput.length <= 24000
                  ? capturedOutput.toString()
                  : '${capturedOutput.toString().substring(0, 12000)}\n[...trimmed; inspect task logs...]\n${capturedOutput.toString().substring(capturedOutput.length - 12000)}',
            }),
          });
          task.remove('pendingCommand');
          await _record(
            task,
            'running',
            'Tool result persisted; requesting model continuation',
          );
          await _agentStep(task);
          return;
        }
        await _record(
          task,
          task['state'] == 'stopping'
              ? 'stopped'
              : code == 0
              ? 'completed'
              : 'failed',
          'Process exited ($code). Child processes and external side effects require independent verification.',
        );
      }());
    } catch (error) {
      _commandTask = null;
      await _record(task, 'failed', 'Dispatch failed: $error');
      unawaited(_serial(_drainQueue));
    }
  }

  Future<void> _drainQueue() async {
    if (_commandTask != null || _hasUnknownCommand) return;
    for (final task in tasks.values) {
      if (task['state'] != 'queued') continue;
      await _record(
        task,
        'awaitingApproval',
        'Previously approved queued command acquired workspace lease',
      );
      await _approve(task['id'] as String);
      return;
    }
  }

  bool get _hasUnknownCommand => tasks.values.any(
    (task) =>
        task['state'] == 'unknown' &&
        (task['kind'] == 'command' || task['pendingCommand'] != null),
  );

  Future<void> _agentStep(Map<String, dynamic> task) async {
    if (task['state'] != 'running') return;
    final cancel = CancelToken();
    final id = task['id'] as String;
    _modelCancels[id] = cancel;
    try {
      if (modelUrl == null || modelName == null) {
        throw StateError(
          'Host model is not configured (EXPERT_REMOTE_MODEL_URL/MODEL)',
        );
      }
      _assertTaskModel(task);
      task['modelIdentity'] ??= _modelIdentity;
      task['modelReference'] ??= {
        'model': modelName,
        'format': modelFormat,
        'host': Uri.tryParse(modelUrl!)?.host,
      };
      if (!await _ensureBudget(task, cancel)) return;
      if (cancel.isCancelled || task['state'] != 'running') return;
      _assertTaskModel(task);
      final round = (task['round'] as int? ?? 0) + 1;
      task['round'] = round;
      final history =
          task.putIfAbsent(
                'history',
                () => <dynamic>[
                  {
                    'role': 'system',
                    'content':
                        'You execute tasks in the fixed workspace $_workspacePath. Use shell only when necessary. Command authorization is enforced by the host policy. You cannot change that policy; do not replay completed tools. Return a clear final result after verifying. No automatic retries of side effects. Shell runs with host account permissions and is not a sandbox.',
                  },
                  {'role': 'user', 'content': task['command']},
                ],
              )
              as List<dynamic>;
      await _record(task, 'running', 'Model request $round dispatched');
      if (jsonEncode(history).length > 512000) {
        throw StateError(
          'Task history reached host bound; inspect result and submit a new goal',
        );
      }
      final rawMessage = await _model.step(
        url: modelUrl!,
        model: modelName!,
        key: modelKey ?? '',
        format: modelFormat,
        history: history,
        cancel: cancel,
        extraTools: [if (mathExecutor != null) mathToolSpec],
      );
      if (task['state'] != 'running' || cancel.isCancelled) return;
      final message = Map<String, dynamic>.from(
        _secrets.sanitize(rawMessage) as Map,
      );
      if (rawMessage['tool_calls'] != null &&
          jsonEncode(rawMessage['tool_calls']) !=
              jsonEncode(message['tool_calls'])) {
        throw StateError('Model tool request contained a host credential');
      }
      history.add(message);
      final calls = message['tool_calls'] as List? ?? [];
      if (calls.isEmpty) {
        task['result'] = message['content'] ?? '';
        await _record(task, 'completed', 'Agent returned final result');
      } else {
        if (calls.length == 1 &&
            calls.first['function']['name'] == 'math_calculate' &&
            mathExecutor != null) {
          final arguments = Map<String, dynamic>.from(
            jsonDecode(calls.first['function']['arguments'] as String) as Map,
          );
          final result = await mathExecutor!(arguments);
          if (task['state'] != 'running' || cancel.isCancelled) return;
          history.add({
            'role': 'tool',
            'tool_call_id': calls.first['id'],
            'content': result,
          });
          await _record(task, 'running', 'Trusted math result persisted');
          await _agentStep(task);
          return;
        }
        if (calls.length == 1 &&
            calls.first['function']['name'] == 'deliver_files') {
          final arguments =
              jsonDecode(calls.first['function']['arguments'] as String) as Map;
          final paths = (arguments['paths'] as List).cast<String>();
          if (paths.length > 30) throw StateError('Too many artifacts');
          final artifacts = <Map<String, dynamic>>[];
          for (final path in paths) {
            final file = await _scopedFile(path);
            final stat = await file.stat();
            artifacts.add({
              'path': path,
              'size': stat.size,
              'modified': stat.modified.toUtc().toIso8601String(),
              'sha256': (await sha256.bind(file.openRead()).first).toString(),
            });
            if (task['state'] != 'running' || cancel.isCancelled) return;
          }
          if (task['state'] != 'running' || cancel.isCancelled) return;
          task['artifacts'] = artifacts;
          history.add({
            'role': 'tool',
            'tool_call_id': calls.first['id'],
            'content': jsonEncode({'artifacts': artifacts}),
          });
          await _record(
            task,
            'running',
            'Final artifact references registered',
          );
          await _agentStep(task);
          return;
        }
        if (calls.length != 1 || calls.first['function']['name'] != 'shell') {
          throw StateError('Unsupported tool response');
        }
        final command = jsonDecode(
          calls.first['function']['arguments'] as String,
        )['command'];
        if (command is! String || command.isEmpty || command.length > 32000) {
          throw StateError('Invalid shell command');
        }
        if (_secrets.redact(command) != command) {
          throw StateError('Model command contained a host credential');
        }
        task['pendingCommand'] = command;
        task['pendingToolId'] = calls.first['id'];
        await _record(
          task,
          'awaitingApproval',
          'Proposed command reached policy boundary',
        );
        await _autoCommand(task, inheritedCancel: cancel);
      }
    } catch (error) {
      if (task['state'] == 'running' && !cancel.isCancelled) {
        await _record(
          task,
          'failed',
          'Agent request failed: ${error.runtimeType}${error is DioException
              ? ' HTTP ${error.response?.statusCode ?? error.type.name}'
              : error is StateError
              ? ': ${error.message}'
              : ''}',
        );
      }
    } finally {
      if (identical(_modelCancels[id], cancel)) _modelCancels.remove(id);
    }
  }

  Future<void> stop(String id) => _serial(() => _stop(id));
  Future<void> _stop(String id) async {
    final task = tasks[id]!;
    if (task['state'] == 'awaitingApproval' ||
        task['state'] == 'queued' ||
        task['state'] == 'waiting_budget') {
      await _record(task, 'stopped', 'Cancelled before dispatch');
      _modelCancels[id]?.cancel('User stopped pending review');
    } else if (task['state'] == 'running') {
      await _record(
        task,
        'stopping',
        'Stop requested; waiting for process exit',
      );
      _modelCancels[id]?.cancel('User stopped remote task');
      final process = _processes[id];
      if (process != null) {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
        } else {
          process.kill(ProcessSignal.sigterm);
        }
      } else {
        if (_drainingCommands.contains(id)) {
          await _record(
            task,
            'unknown',
            'Root exited during stop; child/output completion needs verification, no recycled PID targeted',
          );
        } else {
          await _record(
            task,
            'stopped',
            'Stopped; late model response will be ignored',
          );
        }
      }
    }
  }

  Future<void> _record(
    Map<String, dynamic> task,
    String state,
    String message,
  ) async {
    final snapshot = {
      ...task,
      'state': state,
      'updatedAt': _clock().toUtc().toIso8601String(),
    };
    final revision = await _append({
      'kind': 'state',
      'taskId': task['id'],
      'task': jsonDecode(jsonEncode(snapshot)),
      'message': message,
    });
    snapshot['version'] = revision.toString();
    task.addAll(snapshot);
    final terminal =
        tasks.values
            .where(
              (t) => ['completed', 'failed', 'stopped'].contains(t['state']),
            )
            .toList()
          ..sort(
            (a, b) =>
                (b['updatedAt'] as String).compareTo(a['updatedAt'] as String),
          );
    for (final old in terminal.skip(100)) {
      old.remove('history');
      old.remove('artifacts');
      if (old['result'] is String && (old['result'] as String).length > 2000) {
        old['result'] =
            '${(old['result'] as String).substring(0, 2000)}\n[Older terminal details archived]';
      }
      old['archivedDetails'] = true;
    }
  }

  Future<void> _tail = Future.value();
  Future<int> _append(Map<String, dynamic> event) {
    final done = _tail.then<int>((_) async {
      event = {
        ...Map<String, dynamic>.from(_secrets.sanitize(event) as Map),
        'cursor': _cursor + 1,
        'at': DateTime.now().toUtc().toIso8601String(),
      };
      if (event['task'] is Map) event['task']['version'] = '${_cursor + 1}';
      await File('${directory.path}/events.jsonl').writeAsString(
        '${jsonEncode(event)}\n',
        mode: FileMode.append,
        flush: true,
      );
      _cursor++;
      final visible = {...event};
      if (visible['task'] is Map) {
        visible['task'] = Map<String, dynamic>.from(visible['task'] as Map)
          ..remove('history')
          ..remove('result');
      }
      events.add(visible);
      if (events.length > 1000) events.removeRange(0, events.length - 1000);
      final journal = File('${directory.path}/events.jsonl');
      if (await journal.length() > 8 * 1024 * 1024) {
        final snapshot = {...tasks};
        if (event['task'] is Map) {
          snapshot[event['taskId'] as String] = Map<String, dynamic>.from(
            event['task'] as Map,
          );
        }
        final checkpoint = File('${directory.path}/checkpoint.json.tmp');
        await checkpoint.writeAsString(
          jsonEncode(
            _secrets.sanitize({
              'cursor': _cursor,
              'tasks': snapshot.values.toList(),
            }),
          ),
          flush: true,
        );
        await checkpoint.rename('${directory.path}/checkpoint.json');
        final compact = File('${directory.path}/events.jsonl.tmp');
        await compact.writeAsString(
          '${events.map(jsonEncode).join('\n')}\n',
          flush: true,
        );
        await compact.rename(journal.path);
      }
      return _cursor;
    });
    _tail = done.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return done;
  }

  Future<void> close() async {
    _closing = true;
    _automationTimer?.cancel();
    await _server?.close(force: true);
    // Timer.cancel cannot cancel a Git poll/config write already in flight.
    // Keep the private journal lock until that owned scan and its mutations end.
    await _activeAutomationScan;
    await _mutations;
    await _tail;
    await _lock?.unlock();
    await _lock?.close();
  }

  Future<void> configureAutomation(Map<String, dynamic> input) =>
      _serial(() => _configureAutomation(input));
  Future<void> _configureAutomation(Map<String, dynamic> input) async {
    if (_closing) throw StateError('Host is closing');
    if (jsonEncode(input) != jsonEncode(_secrets.sanitize(input))) {
      throw ArgumentError(
        'Automation contains a host credential; use local references',
      );
    }
    final item = Map<String, dynamic>.from(input['item'] as Map);
    final id = item['id'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id)) {
      throw ArgumentError('Invalid id');
    }
    if (input['type'] == 'environment') {
      if (item['startup'] is! String ||
          item['startup'].toString().length > 32000) {
        throw ArgumentError('Startup command required');
      }
      environments[id] = item;
    } else {
      if (![
        'schedule',
        'file',
        'repository',
        'webhook',
      ].contains(item['trigger'])) {
        throw ArgumentError('Unknown trigger');
      }
      if (item['goal'] is! String || item['goal'].toString().isEmpty) {
        throw ArgumentError('Goal required');
      }
      if (!allowedPolicies.contains(item['policy'] ?? 'request')) {
        throw ArgumentError('Host has not authorized automation policy');
      }
      final roundLimit = item['roundLimit'] ?? maxRounds;
      if (roundLimit is! int || roundLimit < 1 || roundLimit > roundCeiling) {
        throw ArgumentError('Automation round limit exceeds host ceiling');
      }
      if (item['autoBudgetExtension'] == true && !allowAutoBudgetExtension) {
        throw ArgumentError(
          'Host has not authorized automatic budget extension',
        );
      }
      if (item['trigger'] == 'schedule' &&
          ((item['intervalSeconds'] as num? ?? 0) < 30)) {
        throw ArgumentError('Minimum schedule interval is 30 seconds');
      }
      if (item['trigger'] == 'file') {
        await _scopedFile(item['path'] as String? ?? '');
      }
      final previous = automations[id];
      automations[id] = {
        ...?previous,
        ...item,
        if (previous?['lastSignature'] != null)
          'lastSignature': previous!['lastSignature'],
        if (previous?['lastRun'] != null) 'lastRun': previous!['lastRun'],
      };
    }
    await _saveConfig();
  }

  Future<File> _scopedFile(String path) async {
    if (path.isEmpty || path.contains('..') || File(path).isAbsolute) {
      throw ArgumentError('Use a workspace-relative existing file');
    }
    final file = File('$_workspacePath/$path');
    final root = await _scopeRoot();
    final resolved = await file.resolveSymbolicLinks();
    final separator = Platform.pathSeparator;
    if (!resolved.startsWith('$root$separator')) {
      throw ArgumentError('File escapes workspace');
    }
    return file;
  }

  Future<void> _saveConfig() async {
    final file = File('${directory.path}/automation.json.tmp');
    await file.writeAsString(
      jsonEncode({
        'automations': automations.values.toList(),
        'environments': environments.values.toList(),
      }),
      flush: true,
    );
    await file.rename('${directory.path}/automation.json');
  }

  Future<void> _scanAutomations() async {
    if (_scanning || _closing) return;
    _scanning = true;
    try {
      for (final item in automations.values.toList()) {
        if (_closing) break;
        if (item['paused'] == true || item['trigger'] == 'webhook') continue;
        try {
          String signature;
          if (item['trigger'] == 'schedule') {
            signature =
                '${DateTime.now().millisecondsSinceEpoch ~/ ((item['intervalSeconds'] as num).toInt() * 1000)}';
          } else if (item['trigger'] == 'file') {
            final stat = await (await _scopedFile(
              item['path'] as String,
            )).stat();
            signature = '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
          } else {
            final result = await Process.run('git', [
              'rev-parse',
              'HEAD',
            ], workingDirectory: await _scopeRoot());
            if (result.exitCode != 0) {
              throw StateError('Repository HEAD unavailable');
            }
            signature = result.stdout.toString().trim();
          }
          if (item['lastSignature'] == null && item['trigger'] != 'schedule') {
            item['lastSignature'] = signature;
            await _saveConfig();
            continue;
          }
          if (item['lastSignature'] == signature) continue;
          if (item['candidate'] != signature && item['trigger'] != 'schedule') {
            item['candidate'] = signature;
            continue;
          }
          if (_closing) break;
          await trigger(item['id'] as String, signature);
        } catch (error) {
          item['error'] = error.toString();
        }
      }
    } finally {
      _scanning = false;
    }
  }

  Future<void> trigger(String id, String eventId) =>
      _serial(() => _trigger(id, eventId));
  Future<void> _trigger(String id, String eventId) async {
    if (_closing) throw StateError('Host is closing');
    if (_secrets.redact(eventId) != eventId) {
      throw ArgumentError('Webhook identity contains a host credential');
    }
    final item = automations[id];
    if (item == null || item['paused'] == true) {
      throw StateError('Trigger missing or paused');
    }
    if (eventId.isEmpty || eventId.length > 200) {
      throw ArgumentError('Stable eventId required');
    }
    final seen = (item['seen'] as List? ?? []).cast<String>();
    if (seen.contains(eventId) || item['lastSignature'] == eventId) return;
    // Derive submission identity from persistent trigger sequence. A duplicate
    // event cannot execute again even when the caller reconnects.
    final sequence = (item['sequence'] as int? ?? 0) + 1;
    final taskId =
        'auto_${id}_${sha256.convert(utf8.encode(eventId)).toString().substring(0, 16)}';
    if (tasks.containsKey(taskId)) return;
    final task = await _submit({
      'id': taskId,
      'goal': item['goal'],
      'policy': item['policy'] ?? 'request',
      'roundLimit': item['roundLimit'] ?? maxRounds,
      'autoBudgetExtension': item['autoBudgetExtension'] == true,
    });
    task['trigger'] = {
      'automation': id,
      'eventId': eventId,
      'kind': item['trigger'],
    };
    await _record(
      task,
      'awaitingApproval',
      'Automation triggered; approval required',
    );
    item['lastSignature'] = eventId;
    item['sequence'] = sequence;
    item['lastRun'] = DateTime.now().toUtc().toIso8601String();
    item['seen'] = [
      ...seen,
      eventId,
    ].reversed.take(100).toList().reversed.toList();
    item.remove('error');
    await _saveConfig();
    if (item['autoStartModel'] == true && task['state'] == 'awaitingApproval') {
      await _approve(taskId);
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > 65536) throw ArgumentError('Request too large');
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  }

  Future<void> _respond(HttpRequest request, Object body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.write(jsonEncode(_secrets.sanitize(body)));
    await request.response.close();
  }
}
