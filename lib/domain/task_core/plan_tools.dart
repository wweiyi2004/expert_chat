import '../llm/llm_provider.dart';

const taskPlanTools = [
  ToolSpec(
    name: 'work_get_plan',
    description: '读取当前会话的版本化计划。计划记录不授予工具权限。',
    parameters: {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
  ),
  ToolSpec(
    name: 'work_set_plan',
    description:
        '保存执行步骤。普通工作任务用于进度记录；用户选择计划模式时提交待审方案并结束本轮，不能自行批准。简单明确任务不必创建计划。',
    parameters: {
      'type': 'object',
      'properties': {
        'expected_revision': {'type': 'integer'},
        'body': {'type': 'string'},
        'steps': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['expected_revision', 'body', 'steps'],
      'additionalProperties': false,
    },
  ),
  ToolSpec(
    name: 'work_plan_progress',
    description:
        '每完成一项必须立即更新为 completed；开始一项更新为 running，不能仅在正文声称完成。完成全部步骤后清单会自动收起。只根据实际进展更新；完成声明不等于任务验收，可提供真实工具调用 ID 作为证据。',
    parameters: {
      'type': 'object',
      'properties': {
        'revision': {'type': 'integer'},
        'step_id': {'type': 'string'},
        'status': {
          'type': 'string',
          'enum': ['pending', 'running', 'completed', 'cancelled'],
        },
        'evidence': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['revision', 'step_id', 'status'],
      'additionalProperties': false,
    },
  ),
];
