import 'dart:async';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/features/chat/widgets/chat_workspace_options.dart';
import 'package:expert_chat/state/conversation_workspace_bindings.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/research_terminal_controller.dart';
import 'package:expert_chat/data/research/ssh_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'desktop_workspaces_page_test.dart' show MemoryHost;

class _Research extends ResearchTerminalController {
  @override
  ResearchTerminalState build() => const ResearchTerminalState(
    profiles: [
      SshProfile(id: 'ssh-a', name: 'A', host: 'a', username: 'u'),
      SshProfile(id: 'ssh-b', name: 'B', host: 'b', username: 'u'),
    ],
  );
}

class _FailBindings extends ConversationWorkspaceBindings {
  @override
  Map<String, String> build() => {'chat': 'old-local'};
  @override
  Future<void> select(String conversationId, String? workspaceId) async {
    throw StateError('binding save failed');
  }
}

class _GateBindings extends ConversationWorkspaceBindings {
  final gate = Completer<void>();
  @override
  Map<String, String> build() => {'chat': 'old-local'};
  @override
  Future<void> select(String conversationId, String? workspaceId) async {
    await gate.future;
    await super.select(conversationId, workspaceId);
  }
}

class _GatePolicies extends SessionPolicies {
  final gate = Completer<void>();
  @override
  Map<String, SessionPolicy> build() => {
    'chat': const SessionPolicy(
      sshProfileId: 'ssh-a',
      remoteRoot: '/old',
      approval: WorkApprovalMode.assisted,
      network: false,
      toolRounds: 9,
    ),
  };
  @override
  Future<void> save(String id, SessionPolicy policy) async {
    await gate.future;
    throw StateError('policy save failed');
  }
}

Future<void> _open(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: ChatWorkspaceBar(conversationId: 'chat', busy: false),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('chat-workspace-bar')));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    160,
    scrollable: find
        .descendant(
          of: find.byType(ListView).last,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'work options defaults automatically and can bind or release a project',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final host = MemoryHost();
      await host.add(
        id: 'project',
        name: '项目工作区',
        path: 'E:/project',
        access: WorkspaceAccess.readOnly,
      );
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          desktopWorkspaceHostProvider.overrideWithValue(host),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: ChatWorkspaceBar(conversationId: 'chat', busy: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('E:/App/desktop-workspaces/default'),
        findsOneWidget,
      );
      expect(container.read(conversationWorkspaceBindingsProvider), isEmpty);
      await tester.tap(find.byKey(const ValueKey('chat-workspace-bar')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('select-workspace-project')),
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-workspace-project')));
      await tester.pumpAndSettle();
      expect(
        container.read(conversationWorkspaceBindingsProvider)['chat'],
        'project',
      );
      expect(find.byTooltip('E:/project'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-workspace-bar')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('use-default-workspace')),
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('use-default-workspace')));
      await tester.pumpAndSettle();
      expect(container.read(conversationWorkspaceBindingsProvider), isEmpty);
      expect(
        find.byTooltip('E:/App/desktop-workspaces/default'),
        findsOneWidget,
      );
    },
  );
  testWidgets('failed local binding keeps active SSH and all policy fields', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        desktopWorkspaceHostProvider.overrideWithValue(MemoryHost()),
        conversationWorkspaceBindingsProvider.overrideWith(_FailBindings.new),
        researchTerminalProvider.overrideWith(_Research.new),
      ],
    );
    addTearDown(container.dispose);
    const original = SessionPolicy(
      sshProfileId: 'ssh-a',
      remoteRoot: '/old',
      approval: WorkApprovalMode.assisted,
      network: false,
      toolRounds: 9,
    );
    await container.read(sessionPolicyProvider.notifier).save('chat', original);
    await _open(tester, container);
    await _choose(tester, 'use-default-workspace');
    expect(find.textContaining('binding save failed'), findsOneWidget);
    expect(
      container.read(sessionPolicyProvider)['chat']!.toJson(),
      original.toJson(),
    );
    expect(
      container.read(conversationWorkspaceBindingsProvider)['chat'],
      'old-local',
    );
  });
  for (final concurrent in [false, true]) {
    testWidgets(
      'failed SSH clearing rolls back only unchanged staged local binding concurrent=$concurrent',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final gate = _GatePolicies();
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
            desktopWorkspaceHostProvider.overrideWithValue(MemoryHost()),
            sessionPolicyProvider.overrideWith(() => gate),
            researchTerminalProvider.overrideWith(_Research.new),
          ],
        );
        addTearDown(container.dispose);
        await container
            .read(conversationWorkspaceBindingsProvider.notifier)
            .select('chat', 'old-local');
        final original = container
            .read(sessionPolicyProvider)['chat']!
            .toJson();
        await _open(tester, container);
        await tester.tap(find.byKey(const ValueKey('use-default-workspace')));
        await tester.pump();
        if (concurrent) {
          await container
              .read(conversationWorkspaceBindingsProvider.notifier)
              .select('chat', 'later-selection');
        }
        gate.gate.complete();
        await tester.pumpAndSettle();
        expect(
          container.read(sessionPolicyProvider)['chat']!.toJson(),
          original,
        );
        expect(
          container.read(conversationWorkspaceBindingsProvider)['chat'],
          concurrent ? 'later-selection' : 'old-local',
        );
      },
    );
  }
  testWidgets(
    'SSH shared directory display matches selection and local choice preserves unrelated policy',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          desktopWorkspaceHostProvider.overrideWithValue(MemoryHost()),
          researchTerminalProvider.overrideWith(_Research.new),
        ],
      );
      addTearDown(container.dispose);
      const original = SessionPolicy(
        sshProfileId: 'ssh-a',
        remoteRoot: '/shared',
        approval: WorkApprovalMode.assisted,
        network: false,
        toolRounds: 9,
      );
      await container
          .read(sessionPolicyProvider.notifier)
          .save('chat', original);
      await _open(tester, container);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('select-ssh-ssh-b')),
        160,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('会话目录 /shared · 使用SSH账号读写权限'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('select-ssh-ssh-b')));
      await tester.pumpAndSettle();
      expect(
        container.read(sessionPolicyProvider)['chat']!.toJson(),
        original.copyWith(sshProfileId: 'ssh-b').toJson(),
      );
      await tester.tap(find.byKey(const ValueKey('chat-workspace-bar')));
      await tester.pumpAndSettle();
      await _choose(tester, 'use-default-workspace');
      final localPolicy = original.copyWith(sshProfileId: '');
      expect(
        container.read(sessionPolicyProvider)['chat']!.toJson(),
        localPolicy.toJson(),
      );
      await tester.tap(find.byKey(const ValueKey('chat-workspace-bar')));
      await tester.pumpAndSettle();
      await _choose(tester, 'use-default-workspace');
      expect(
        container.read(sessionPolicyProvider)['chat']!.toJson(),
        localPolicy.toJson(),
      );
    },
  );
  testWidgets(
    'local commit clears SSH without overwriting concurrently changed permission or rounds',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final bindings = _GateBindings();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          desktopWorkspaceHostProvider.overrideWithValue(MemoryHost()),
          conversationWorkspaceBindingsProvider.overrideWith(() => bindings),
          researchTerminalProvider.overrideWith(_Research.new),
        ],
      );
      addTearDown(container.dispose);
      const original = SessionPolicy(sshProfileId: 'ssh-a', remoteRoot: '/old');
      await container
          .read(sessionPolicyProvider.notifier)
          .save('chat', original);
      await _open(tester, container);
      await tester.tap(find.byKey(const ValueKey('use-default-workspace')));
      await tester.pump();
      final latest = original.copyWith(
        approval: WorkApprovalMode.full,
        toolRounds: 73,
        network: false,
      );
      await container.read(sessionPolicyProvider.notifier).save('chat', latest);
      bindings.gate.complete();
      await tester.pumpAndSettle();
      expect(
        container.read(sessionPolicyProvider)['chat']!.toJson(),
        latest.copyWith(sshProfileId: '').toJson(),
      );
    },
  );
}
