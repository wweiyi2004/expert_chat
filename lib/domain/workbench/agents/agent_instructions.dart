import '../../../data/models.dart';
import '../../../data/agent_defaults.dart';
import '../../llm/llm_provider.dart';

/// Keep user instructions separate from tool contracts and from the other role.
abstract final class AgentInstructions {
  static const mainMarker = '【用户自定义：工作主代理系统指令】\n';
  static const childMarker = '【用户自定义：子代理系统指令】\n';
  static const defaultMainMarker = '【默认：工作主代理系统指令】\n';
  static void replaceChild(
    List<LlmRequestMessage> messages, {
    required String core,
    required String instructions,
    String role = '',
  }) {
    final common = instructions.trim().isEmpty
        ? AgentDefaults.child
        : instructions.trim();
    // Factory roles include the common default; avoid sending it twice.
    final specialty = role.trim().startsWith(common)
        ? role.trim().substring(common.length).trim()
        : role.trim();
    replace(
      messages,
      [
        if (core.trim().isNotEmpty) '【全局提示词】\n${core.trim()}',
        if (specialty.isNotEmpty) '【专业角色】\n$specialty',
        '【子代理通用指令】\n$common',
      ].join('\n\n'),
      subagent: true,
    );
  }

  static void replace(
    List<LlmRequestMessage> messages,
    String instructions, {
    bool subagent = false,
  }) {
    final marker = subagent ? childMarker : mainMarker;
    messages.removeWhere(
      (m) =>
          m.role == MessageRole.system &&
          (m.content.startsWith(marker) ||
              (!subagent && m.content.startsWith(defaultMainMarker))),
    );
    final custom = instructions.trim();
    final value = custom.isEmpty && !subagent ? AgentDefaults.work : custom;
    if (value.isNotEmpty) {
      messages.add(
        LlmRequestMessage(
          role: MessageRole.system,
          content:
              '${custom.isEmpty && !subagent ? defaultMainMarker : marker}$value',
        ),
      );
    }
  }
}
