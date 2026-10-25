import '../../llm/llm_provider.dart';

const mathToolSpec = ToolSpec(
  name: 'math_calculate',
  description:
      '使用电脑 Python/SymPy 数学后端进行精确分数/根式、化简、微积分、实数方程求解、数值、统计、绘图和等式验证。手机通过已配对的受保护电脑连接执行。仅支持白名单数学表达式，乘方用 **，函数 sqrt/sin/cos/tan/asin/acos/atan/exp/log/Abs，常量 pi/E/I。缺少后端时明确返回不可用，不以猜测代替计算。plot 返回 SVG 与采样点；verify 的 equal=null 表示未能证明，原始定义域限制必须保留。',
  parameters: {
    'type': 'object',
    'properties': {
      'operation': {
        'type': 'string',
        'enum': [
          'exact',
          'simplify',
          'differentiate',
          'integrate',
          'solve',
          'numeric',
          'statistics',
          'plot',
          'verify',
        ],
      },
      'expression': {'type': 'string', 'description': '数学表达式；solve 将其设为 0'},
      'variable': {'type': 'string', 'description': '变量，默认 x'},
      'rhs': {'type': 'string', 'description': 'verify 的右侧表达式'},
      'digits': {'type': 'integer', 'minimum': 2, 'maximum': 100},
      'values': {
        'type': 'array',
        'items': {'type': 'string'},
        'maxItems': 512,
      },
      'min': {'type': 'number'},
      'max': {'type': 'number'},
    },
    'required': ['operation'],
    'additionalProperties': false,
  },
);
