import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:expert_chat/domain/desktop/workspace_tools.dart';
import 'package:expert_chat/domain/workbench/changes/restore_work_file_change.dart';
import 'package:expert_chat/features/workbench/changes/work_changes_page.dart';
import 'package:expert_chat/features/workbench/files/work_file_access.dart';
import 'package:expert_chat/state/work_changes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Session implements WorkToolSession {
  _Session(this.root, {this.prefix = ''});
  final String root, prefix;
  String hash = 'registered';
  bool denied = false;
  final calls = <String>[];
  @override
  get tools => const [
    ToolSpec(
      name: 'coding_artifact_manifest',
      description: 'metadata',
      parameters: {},
    ),
  ];
  @override
  String get target => root;
  @override
  String get changeTarget => jsonEncode({
    'kind': 'local',
    'workspaceId': 'fixture',
    'root': root,
    'scopes': {'root': root},
    if (prefix.isNotEmpty) 'pathPrefix': prefix,
  });
  @override
  String get guidance => '';
  @override
  Future<void> close() async {}
  @override
  Future<String> call(
    String name,
    Map<String, dynamic> args,
    CancelToken token, {
    onOutput,
    onComplete,
  }) async {
    calls.add(name);
    if (denied) throw StateError('Permission revoked');
    final path = p.join(root, prefix, args['path'] as String);
    if (name == 'coding_artifact_manifest') {
      return jsonEncode({
        'sha256': hash,
        'kind': Directory(path).existsSync() ? 'directory' : 'file',
        'bytes': File(path).existsSync() ? File(path).lengthSync() : 0,
      });
    }
    final file = File(path);
    if (name == 'coding_delete_file_if_current') {
      if (!file.existsSync() ||
          sha256.convert(file.readAsBytesSync()).toString() !=
              args['expected_sha256']) {
        throw StateError('version changed');
      }
      file.deleteSync();
      return '{"deleted":true}';
    }
    if (name == 'coding_write_file') {
      if (args['expected_sha256'] == 'new' && file.existsSync()) {
        throw StateError('existing replacement preserved');
      }
      file.writeAsStringSync(args['content'] as String);
      return jsonEncode({
        'sha256': sha256.convert(file.readAsBytesSync()).toString(),
      });
    }
    throw StateError('Body read must not be used to reveal an artifact');
  }
}

WorkFileChange _file(
  String path,
  String hash, {
  Map<String, dynamic>? manifest,
  String target = 'fixture',
}) => WorkFileChange(
  id: 'snapshot',
  conversationId: 'c',
  assistantId: 'a',
  target: target,
  scope: 'root',
  path: path,
  before: null,
  after: 'created content\n',
  beforeHash: null,
  afterHash: hash,
  updatedAt: DateTime(2026),
  artifactManifest: manifest,
);

class _Review extends WorkChanges {
  static late WorkFileChange seed;
  int sequence = 0;
  @override
  List<WorkFileChange> build() {
    ready = Future.value();
    return [seed];
  }

  @override
  Future<void> markReverted(WorkFileChange change) async {
    state = [
      for (final e in state)
        if (e.id == change.id) e.withReverted() else e,
    ];
  }

  @override
  Future<void> record({
    required String conversationId,
    String assistantId = '',
    String roundId = '',
    Map<String, dynamic>? artifactManifest,
    bool beforeKnown = true,
    bool textSnapshot = true,
    required String target,
    String scope = 'root',
    required String path,
    String? before,
    required String? after,
    bool deleted = false,
    String? beforeHash,
    required String afterHash,
  }) async {
    state = [
      ...state,
      WorkFileChange(
        id: 'recreated-${++sequence}',
        conversationId: conversationId,
        assistantId: assistantId,
        target: target,
        scope: scope,
        path: path,
        before: before,
        after: after,
        beforeKnown: beforeKnown,
        textSnapshot: textSnapshot,
        deleted: deleted,
        artifactManifest: artifactManifest,
        beforeHash: beforeHash,
        afterHash: afterHash,
        updatedAt: DateTime(2026),
        roundId: roundId,
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'new file UI deletes reviewed version, recreates snapshot, and protects a human replacement',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final temp = Directory.systemTemp.createTempSync('new-file-rollback-ui-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'new.txt'))
        ..writeAsStringSync('created content\n');
      final hash = sha256.convert(file.readAsBytesSync()).toString();
      _Review.seed = _file('new.txt', hash);
      final session = _Session(temp.path);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [workChangesProvider.overrideWith(_Review.new)],
          child: MaterialApp(
            home: WorkChangesPage(
              conversationId: 'c',
              restore: (change) => restoreReviewedFileChange(
                session,
                change,
                CancelToken(),
              ).then((_) {}),
            ),
          ),
        ),
      );
      Future<void> undo() async {
        await tester.tap(find.text('撤销该文件改动'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('核验版本并删除'));
        await tester.pumpAndSettle();
      }

      await undo();
      expect(file.existsSync(), isFalse);
      await tester.tap(find.text('从快照重新创建（已有文件时拒绝）'));
      await tester.pumpAndSettle();
      expect(file.readAsStringSync(), 'created content\n');
      await undo();
      expect(file.existsSync(), isFalse);
      file.writeAsStringSync('human replacement');
      await tester.tap(find.text('从快照重新创建（已有文件时拒绝）'));
      await tester.pumpAndSettle();
      expect(file.readAsStringSync(), 'human replacement');
      expect(
        find.textContaining('existing replacement preserved'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'reveal authorization supports directory root, 9MiB file and isolated prefix without body reads',
    () async {
      final temp = await Directory.systemTemp.createTemp('artifact-reveal-');
      addTearDown(() => temp.delete(recursive: true));
      final large = File(p.join(temp.path, 'large.bin'))
        ..writeAsBytesSync(List.filled(9 * 1024 * 1024, 17));
      final root = _Session(temp.path);
      expect(
        await authorizedDeliveryLocalPath(
          root,
          _file(
            '.',
            'registered',
            manifest: {'kind': 'directory'},
          ).withDelivery(true),
          CancelToken(),
        ),
        p.normalize(temp.path),
      );
      expect(
        await authorizedDeliveryLocalPath(
          root,
          _file('large.bin', 'registered').withDelivery(true),
          CancelToken(),
        ),
        p.normalize(large.path),
      );
      const prefix = '.expert-agent-worktrees/fixture-child';
      final child = await Directory(
        p.join(temp.path, prefix, 'dist'),
      ).create(recursive: true);
      final isolated = _Session(temp.path, prefix: prefix);
      expect(
        await authorizedDeliveryLocalPath(
          isolated,
          _file(
            'dist',
            'registered',
            manifest: {'kind': 'directory'},
          ).withDelivery(true),
          CancelToken(),
        ),
        p.normalize(child.path),
      );
      expect(
        root.calls.every((name) => name == 'coding_artifact_manifest'),
        isTrue,
      );
      root.hash = 'externally changed';
      await expectLater(
        authorizedDeliveryLocalPath(
          root,
          _file('large.bin', 'registered').withDelivery(true),
          CancelToken(),
        ),
        throwsStateError,
      );
      root.denied = true;
      await expectLater(
        authorizedDeliveryLocalPath(
          root,
          _file('.', 'registered').withDelivery(true),
          CancelToken(),
        ),
        throwsStateError,
      );
    },
  );
}
