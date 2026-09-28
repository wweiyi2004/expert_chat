import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'synthetic archive search remains bounded at 10k and 100k messages',
    () async {
      final results = <Map<String, Object>>[];
      for (final count in [10000, 100000]) {
        final sandbox = await Directory.systemTemp.createTemp(
          'expert-archive-benchmark-',
        );
        final db = AppDatabase(
          NativeDatabase(File('${sandbox.path}/archive.sqlite')),
        );
        try {
          await db.customStatement(
            "INSERT INTO conversations(id,title,updated_at) VALUES ('benchmark','Synthetic archive',1700000000)",
          );
          await db.customStatement(
            'WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < ?) '
            'INSERT INTO messages(id,convo_id,role,content,created_at,seq) '
            "SELECT CAST(x AS TEXT),'benchmark','user',?,1700000000+x,x FROM n",
            [count, '维护基准材料 ${'synthetic content ' * 30}'],
          );
          final repo = DriftConversationRepository(db);
          final elapsed = <int>[];
          for (var run = 0; run < 6; run++) {
            final watch = Stopwatch()..start();
            final hits = await repo.searchMessages('维护基准');
            watch.stop();
            expect(hits.length, conversationSearchLimit);
            if (run > 0) elapsed.add(watch.elapsedMicroseconds);
          }
          final missing = Stopwatch()..start();
          expect(await repo.searchMessages('no-such-term'), isEmpty);
          missing.stop();
          elapsed.sort();
          results.add({
            'messages': count,
            'databaseBytes': await File(
              '${sandbox.path}/archive.sqlite',
            ).length(),
            'matchingP50Ms': elapsed[2] / 1000,
            'matchingMaxMs': elapsed.last / 1000,
            'noMatchMs': missing.elapsedMicroseconds / 1000,
            'resultLimit': conversationSearchLimit,
          });
        } finally {
          await db.close();
          final resolved = await sandbox.resolveSymbolicLinks();
          final tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
          if (!resolved.startsWith(
            '$tempRoot${Platform.pathSeparator}expert-archive-benchmark-',
          )) {
            throw StateError('Unexpected benchmark cleanup path');
          }
          await sandbox.delete(recursive: true);
        }
      }
      final out = File('output/benchmarks/archive.json');
      await out.parent.create(recursive: true);
      await out.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'platform': Platform.operatingSystem,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'dart': Platform.version,
          'mode': 'Flutter test, synthetic local SQLite; not device SLA',
          'results': results,
        }),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
