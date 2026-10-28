import 'package:expert_chat/data/agent_defaults.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/workbench/agents/agent_instructions.dart';
import 'package:expert_chat/domain/desktop/workspace_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'scope validation accepts declared named scopes and rejects display names',
    () {
      final tools = [
        const ToolSpec(
          name: 'coding_read_file',
          description: '',
          parameters: {
            'properties': {
              'scope': {
                'enum': ['root', 'source'],
              },
            },
          },
        ),
      ];
      final arguments = <String, dynamic>{'scope': 'source', 'path': 'a.txt'};
      validateWorkspaceScope(tools, 'coding_read_file', arguments);
      expect(arguments['scope'], 'source');
      expect(
        () =>
            validateWorkspaceScope(tools, 'coding_read_file', {'scope': 'AI'}),
        throwsA(isA<WorkspaceScopeException>()),
      );
    },
  );
  test(
    'child receives shared voice, common instructions and specialty once',
    () {
      final messages = <LlmRequestMessage>[
        const LlmRequestMessage(
          role: MessageRole.user,
          content: 'Read the logs',
        ),
      ];
      for (var i = 0; i < 2; i++) {
        AgentInstructions.replaceChild(
          messages,
          core: 'CORE: explain plainly',
          instructions: 'CHILD: report findings',
          role: 'ROLE: inspect logs',
        );
      }
      expect(messages.where((m) => m.role == MessageRole.system), hasLength(1));
      expect(messages.last.content, contains('CORE: explain plainly'));
      expect(messages.last.content, contains('CHILD: report findings'));
      expect(messages.last.content, contains('ROLE: inspect logs'));
      expect(messages.first.content, 'Read the logs');
    },
  );

  test('factory child text is not duplicated by a specialty', () {
    final messages = <LlmRequestMessage>[];
    AgentInstructions.replaceChild(
      messages,
      core: '',
      instructions: '',
      role: '${AgentDefaults.child}\nRead source code',
    );
    expect(
      AgentDefaults.child.allMatches(messages.single.content),
      hasLength(1),
    );
    expect(messages.single.content, contains('Read source code'));
  });
}
