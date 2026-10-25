import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/workbench/changes/delivery_snapshot.dart';
import 'package:expert_chat/state/work_changes.dart';

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

WorkFileChange file(
  String path, {
  String hash = 'v1',
  String? deliveryHash,
  bool reverted = false,
  String assistant = 'answer',
  String target = 'workspace',
}) => WorkFileChange(
  id: '$path-$hash',
  conversationId: 'conversation',
  assistantId: assistant,
  target: target,
  scope: 'root',
  path: path,
  before: null,
  after: 'content',
  beforeHash: null,
  afterHash: hash,
  updatedAt: DateTime(2026, 10, 23),
  deliveryHash: deliveryHash,
  reverted: reverted,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('binary artifacts retain identity without fabricating a text diff', () {
    expect(
      deliverySnapshotText({
        'encoding': 'base64',
        'content': base64Encode([137, 80, 78, 71]),
      }, 'figure.png'),
      isNull,
    );
    expect(
      deliverySnapshotText({
        'encoding': 'base64',
        'content': base64Encode(utf8.encode('%PDF-1.7')),
      }, 'report.pdf'),
      isNull,
    );
    expect(
      deliverySnapshotText({
        'encoding': 'base64',
        'content': base64Encode(utf8.encode('最终报告')),
      }, 'report.md'),
      '最终报告',
    );
  });

  test(
    'manifest replacement, command invalidation, and re-publication after revert persist correctly',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'expert-delivery-test-',
      );
      final original = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TemporaryPaths(temporary.path);
      final container = ProviderContainer();
      try {
        final store = container.read(workChangesProvider.notifier);
        await store.ready;
        Future<void> record(String path, String hash, {bool binary = false}) =>
            store.record(
              conversationId: 'c',
              assistantId: 'a',
              target: 't',
              path: path,
              after: binary ? '' : hash,
              afterHash: hash,
              textSnapshot: !binary,
            );
        Future<void> register(Map<String, String> files) =>
            store.registerDeliveries(
              conversationId: 'c',
              assistantId: 'a',
              target: 't',
              scope: 'root',
              verifiedFiles: files,
            );
        List<WorkFileChange> selected() =>
            finalDeliveryFiles(container.read(workChangesProvider), 'c', 'a');
        await record('debug.log', 'log');
        await record('report.md', 'v1');
        await record('figure.png', 'png', binary: true);
        await register({'report.md': 'v1', 'figure.png': 'png'});
        expect(selected().length, 2);
        expect(selected().last.beforeKnown, isFalse);
        await register({'report.md': 'v1'});
        expect(selected().map((e) => e.path), ['report.md']);
        await store.commandStarted('c', 'a', 't');
        expect(selected(), isEmpty);
        await register({'report.md': 'v1'});
        await store.markReverted(selected().single);
        expect(selected(), isEmpty);
        await record('report.md', 'v1');
        await register({'report.md': 'v1'});
        expect(selected().single.afterHash, 'v1');
        await expectLater(
          register({'report.md': 'not-current'}),
          throwsStateError,
        );
        expect(selected().single.afterHash, 'v1');
        final restored = ProviderContainer();
        try {
          await restored.read(workChangesProvider.notifier).ready;
          expect(
            finalDeliveryFiles(
              restored.read(workChangesProvider),
              'c',
              'a',
            ).single.path,
            'report.md',
          );
        } finally {
          restored.dispose();
        }
      } finally {
        container.dispose();
        PathProviderPlatform.instance = original;
        await temporary.delete(recursive: true);
      }
    },
  );
  test(
    'isolated and parent aliases invalidate the same physical delivery and parent directory manifest',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'delivery-alias-',
      );
      final original = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TemporaryPaths(temporary.path);
      final container = ProviderContainer();
      try {
        final store = container.read(workChangesProvider.notifier);
        await store.ready;
        final parent = jsonEncode({
          'kind': 'local',
          'workspaceId': 'p',
          'root': 'C:/fixture',
          'scopes': {'root': 'C:/fixture'},
        });
        final child = jsonEncode({
          ...jsonDecode(parent) as Map,
          'pathPrefix': '.expert-agent-worktrees/child',
        });
        Future<void> publish(
          String target,
          String path,
          String hash, {
          Map<String, dynamic>? manifest,
        }) async {
          await store.record(
            conversationId: 'c',
            assistantId: 'a',
            target: target,
            path: path,
            after: '',
            afterHash: hash,
            textSnapshot: false,
            artifactManifest: manifest,
          );
          await store.registerDeliveries(
            conversationId: 'c',
            assistantId: 'a',
            target: target,
            scope: 'root',
            verifiedFiles: {path: hash},
          );
        }

        await publish(parent, '.expert-agent-worktrees/child/file.txt', 'v1');
        await store.record(
          conversationId: 'c',
          assistantId: 'a',
          target: child,
          path: 'file.txt',
          after: 'new',
          afterHash: 'v2',
        );
        expect(
          container.read(workChangesProvider).where((e) => e.isDelivery),
          isEmpty,
        );
        await publish(child, 'file.txt', 'v2');
        await store.record(
          conversationId: 'c',
          assistantId: 'a',
          target: parent,
          path: '.expert-agent-worktrees/child/file.txt',
          after: 'third',
          afterHash: 'v3',
        );
        expect(
          container.read(workChangesProvider).where((e) => e.isDelivery),
          isEmpty,
        );
        await publish(
          parent,
          '.expert-agent-worktrees/child/dist',
          'directory-v1',
          manifest: {'kind': 'directory'},
        );
        await store.record(
          conversationId: 'c',
          assistantId: 'a',
          target: child,
          path: 'dist/new.bin',
          after: '',
          afterHash: 'binary-v2',
          textSnapshot: false,
        );
        expect(
          container.read(workChangesProvider).where((e) => e.isDelivery),
          isEmpty,
        );
        expect(container.read(workChangesProvider).last.target, child);
        expect(container.read(workChangesProvider).last.path, 'dist/new.bin');
      } finally {
        container.dispose();
        PathProviderPlatform.instance = original;
        await temporary.delete(recursive: true);
      }
    },
  );
  test('writing probes and final files never implicitly publishes them', () {
    final entries = [file('probe.py'), file('report.md'), file('debug.log')];
    expect(finalDeliveryFiles(entries, 'conversation', 'answer'), isEmpty);
    entries[1] = entries[1].withDelivery(true);
    expect(
      finalDeliveryFiles(entries, 'conversation', 'answer').map((f) => f.path),
      ['report.md'],
    );
  });

  test(
    'editing a published version withdraws it until explicitly registered again',
    () {
      final original = file('report.md').withDelivery(true);
      final replacement = file('report.md', hash: 'v2');
      expect(
        finalDeliveryFiles([original, replacement], 'conversation', 'answer'),
        isEmpty,
      );
      expect(
        finalDeliveryFiles(
          [original, replacement.withDelivery(true)],
          'conversation',
          'answer',
        ).single.afterHash,
        'v2',
      );
    },
  );

  test('revert and mismatched version cannot resurrect a prior delivery', () {
    final original = file('report.md').withDelivery(true);
    expect(
      finalDeliveryFiles(
        [original, original.withReverted()],
        'conversation',
        'answer',
      ),
      isEmpty,
    );
    expect(
      file('report.md', hash: 'v2', deliveryHash: 'v1').isDelivery,
      isFalse,
    );
  });

  test(
    'legacy snapshots stay review records; explicit selection survives storage',
    () {
      final original = file('report.md');
      final legacy = original.toJson()..remove('deliveryHash');
      expect(WorkFileChange.fromJson(legacy).isDelivery, isFalse);
      expect(
        WorkFileChange.fromJson(
          original.withDelivery(true).toJson(),
        ).isDelivery,
        isTrue,
      );
      expect(
        original.withDelivery(true).withDelivery(false).isDelivery,
        isFalse,
      );
    },
  );

  test('same names in different targets and turns keep their own identity', () {
    final entries = [
      file('report.md').withDelivery(true),
      file('report.md', target: 'other').withDelivery(true),
      file('report.md', assistant: 'other-answer').withDelivery(true),
    ];
    expect(finalDeliveryFiles(entries, 'conversation', 'answer').length, 2);
    expect(
      finalDeliveryFiles(entries, 'another-conversation', 'answer'),
      isEmpty,
    );
  });
}
