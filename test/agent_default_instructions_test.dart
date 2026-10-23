import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/data/agent_defaults.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/subagent_role.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/workbench/agents/agent_instructions.dart';
import 'package:expert_chat/features/settings/widgets/agent_instructions_editor.dart';

void main() {
  test(
    'main default, custom override, and reset replace each other without accumulation',
    () {
      final messages = <LlmRequestMessage>[
        const LlmRequestMessage(role: MessageRole.user, content: 'task'),
      ];
      AgentInstructions.replace(messages, '');
      expect(messages.last.content, contains(AgentDefaults.work));
      AgentInstructions.replace(messages, 'my instructions');
      expect(messages.length, 2);
      expect(
        messages.last.content,
        '${AgentInstructions.mainMarker}my instructions',
      );
      AgentInstructions.replace(messages, '');
      AgentInstructions.replace(messages, '');
      expect(messages.length, 2);
      expect(messages.last.content, contains(AgentDefaults.work));
    },
  );

  test(
    'child instructions remain independent and legacy customization is preserved',
    () {
      final roles = SubagentRole.defaults('my child instructions');
      expect(roles.first.instructions, 'my child instructions');
      expect(
        roles
            .skip(1)
            .every((role) => role.instructions.contains(AgentDefaults.child)),
        isTrue,
      );
      final messages = <LlmRequestMessage>[];
      AgentInstructions.replace(
        messages,
        roles.first.instructions,
        subagent: true,
      );
      expect(messages.single.content, contains('my child instructions'));
      expect(messages.single.content, isNot(contains(AgentDefaults.work)));
    },
  );

  testWidgets('editor displays defaults and reset persists default selection', (
    tester,
  ) async {
    String? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentInstructionsEditor(
            title: 'Work',
            description: 'Instructions',
            value: '',
            defaultValue: 'Ready to work',
            icon: Icons.work,
            onSaved: (value) async {
              saved = value;
            },
          ),
        ),
      ),
    );
    expect(find.text('Ready to work'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'My custom work method');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(saved, 'My custom work method');
    await tester.tap(find.text('恢复默认'));
    await tester.pump();
    expect(saved, '');
    expect(find.text('Ready to work'), findsOneWidget);
  });
}
