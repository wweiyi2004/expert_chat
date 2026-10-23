import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/workbench/processes/work_process_runtime.dart';
import 'package:expert_chat/domain/workbench/processes/work_hook_runtime.dart';

void main() {
  test(
    'configured hook debounces changes and suppresses its own output while running',
    () async {
      final runtime = WorkProcessRuntime();
      final changes = StreamController<String>.broadcast();
      final finish = Completer<WorkProcessResult>();
      var launches = 0;
      final hook = WorkHookDefinition(
        id: 'h',
        conversationId: 'c',
        root: '/granted',
        command: 'fixed-approved-command',
        watchPath: 'src',
        debounceMs: 200,
      );
      final hooks = WorkHookRuntime(
        processes: runtime,
        definitions: [hook],
        persist: (_) async {},
        changeFeed: (_) => changes.stream,
      );
      addTearDown(() async {
        hooks.dispose();
        runtime.dispose();
        await changes.close();
      });
      hooks.bind(
        conversationId: 'c',
        root: '/granted',
        launch: (definition) async {
          launches++;
          expect(definition.command, 'fixed-approved-command');
          return runtime.start(
            conversationId: 'c',
            taskId: 't',
            command: definition.command,
            target: definition.root,
            hookId: definition.id,
            execute: (_, _) => finish.future,
          );
        },
      );
      changes.add('build/ignored');
      changes.add('src/a.dart');
      changes.add('src/filename-with-shell-characters; echo unsafe');
      await Future<void>.delayed(const Duration(milliseconds: 240));
      expect(launches, 1);
      changes.add('src/own-generated-output.dart');
      await Future<void>.delayed(const Duration(milliseconds: 240));
      expect(launches, 1);
      final done = runtime.events.first;
      finish.complete(const WorkProcessResult(exitCode: 0));
      await done;
      changes.add('src/output-settling.dart');
      await Future<void>.delayed(const Duration(milliseconds: 240));
      expect(launches, 1);
    },
  );

  test(
    'start returns immediately; command exit emits one event with real logs',
    () async {
      final runtime = WorkProcessRuntime();
      addTearDown(runtime.dispose);
      final finish = Completer<WorkProcessResult>();
      var entered = false;
      final event = runtime.events.first;
      final id = runtime.start(
        conversationId: 'c',
        taskId: 't',
        command: 'build',
        target: 'workspace',
        execute: (_, log) {
          entered = true;
          log('actual compiler output', false);
          return finish.future;
        },
      );
      expect(entered, isFalse);
      expect(runtime.record(id)!.status, WorkProcessStatus.starting);
      await Future<void>.delayed(Duration.zero);
      expect(entered, isTrue);
      finish.complete(const WorkProcessResult(exitCode: 7));
      final complete = await event.timeout(const Duration(seconds: 1));
      expect(runtime.record(id)!.exitCode, 7);
      expect(runtime.record(id)!.status, WorkProcessStatus.failed);
      expect(complete.content, contains('actual compiler output'));
      expect(complete.taskId, 't');
    },
  );

  test(
    'cancel before launch does not execute and leaves a terminal record',
    () async {
      final runtime = WorkProcessRuntime();
      addTearDown(runtime.dispose);
      var entered = false;
      final event = runtime.events.first;
      final id = runtime.start(
        conversationId: 'c',
        taskId: 't',
        command: 'service',
        target: 'workspace',
        service: true,
        execute: (_, _) async {
          entered = true;
          return const WorkProcessResult(exitCode: 0);
        },
      );
      runtime.stop(id);
      await event.timeout(const Duration(seconds: 1));
      expect(entered, isFalse);
      expect(runtime.record(id)!.status, WorkProcessStatus.cancelled);
      expect(runtime.record(id)!.active, isFalse);
    },
  );

  test(
    'restart invokes executor again and journal never reconnects old services',
    () async {
      final runtime = WorkProcessRuntime(), restored = WorkProcessRuntime();
      addTearDown(runtime.dispose);
      addTearDown(restored.dispose);
      var runs = 0;
      final completed = runtime.events.first;
      final id = runtime.start(
        conversationId: 'c',
        taskId: 't',
        command: 'build',
        target: 'workspace',
        execute: (_, _) async {
          runs++;
          return const WorkProcessResult(exitCode: 0);
        },
      );
      await completed;
      final nextEvent = runtime.events.first;
      final next = runtime.restart(id);
      expect(next, isNot(id));
      await nextEvent;
      expect(runs, 2);
      restored.restoreJournal(runtime.journal());
      expect(() => restored.restart(next), throwsStateError);
    },
  );
}
