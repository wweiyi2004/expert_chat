import 'dart:async';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import '../domain/llm/llm_provider.dart';

const workQuestionTool = ToolSpec(
  name: 'work_ask_user',
  description:
      '向用户集中询问必要信息，显示单选、多选或自由输入卡片。只在缺少关键信息或需要用户选择时使用；不要把工具执行批准包装成问题。不预选答案。必答问题会等待用户；可选问题允许跳过。',
  parameters: {
    'type': 'object',
    'properties': {
      'questions': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 3,
        'items': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
            'question': {'type': 'string'},
            'options': {
              'type': 'array',
              'items': {'type': 'string'},
              'maxItems': 8,
            },
            'multiple': {'type': 'boolean'},
            'required': {'type': 'boolean'},
          },
          'required': ['id', 'question'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['questions'],
    'additionalProperties': false,
  },
);

class WorkQuestion {
  WorkQuestion({
    required this.id,
    required this.question,
    required this.options,
    required this.multiple,
    required this.required,
  });
  final String id, question;
  final List<String> options;
  final bool multiple, required;
  static List<WorkQuestion> parse(Map<String, dynamic> args) {
    final values = args['questions'];
    if (values is! List || values.isEmpty || values.length > 3) {
      throw const FormatException('一次请提出 1–3 个问题');
    }
    final ids = <String>{};
    return [
      for (final raw in values)
        (() {
          if (raw is! Map ||
              raw['id'] is! String ||
              raw['question'] is! String) {
            throw const FormatException('问题缺少 id 或内容');
          }
          final id = raw['id'] as String, question = raw['question'] as String;
          final options = (raw['options'] as List? ?? [])
              .cast<String>()
              .toSet()
              .toList();
          if (id.trim().isEmpty ||
              question.trim().isEmpty ||
              !ids.add(id) ||
              options.length > 8) {
            throw const FormatException('问题标识必须唯一，选项最多 8 个');
          }
          return WorkQuestion(
            id: id,
            question: question,
            options: options,
            multiple: raw['multiple'] == true,
            required: raw['required'] != false,
          );
        })(),
    ];
  }
}

class PendingWorkQuestion {
  PendingWorkQuestion({
    required this.id,
    required this.conversationId,
    this.sourceAgentId,
    required this.assistantId,
    required this.questions,
  });
  final String? sourceAgentId;
  final String id, conversationId, assistantId;
  final List<WorkQuestion> questions;
  final answer = Completer<Map<String, dynamic>>();
}

final workQuestionsProvider =
    NotifierProvider<WorkQuestions, List<PendingWorkQuestion>>(
      WorkQuestions.new,
    );

class WorkQuestions extends Notifier<List<PendingWorkQuestion>> {
  final _waiting = <String, PendingWorkQuestion>{};
  @override
  List<PendingWorkQuestion> build() {
    ref.onDispose(() {
      for (final item in _waiting.values) {
        if (!item.answer.isCompleted) item.answer.complete({'cancelled': true});
      }
    });
    return [];
  }

  Future<Map<String, dynamic>> ask(
    PendingWorkQuestion request,
    CancelToken token,
  ) async {
    if (token.isCancelled) return {'cancelled': true};
    _waiting[request.id] = request;
    state = [...state, request];
    try {
      return await Future.any([
        request.answer.future,
        token.whenCancel.then((_) => <String, dynamic>{'cancelled': true}),
      ]);
    } finally {
      _waiting.remove(request.id);
      if (ref.mounted) state = state.where((r) => r.id != request.id).toList();
    }
  }

  void answer(String id, Map<String, dynamic> answers) {
    final request = state.where((r) => r.id == id).firstOrNull;
    if (request == null || request.answer.isCompleted) return;
    for (final q in request.questions) {
      final value = answers[q.id];
      if (value is! Map) throw StateError('请完成问题');
      final selected = (value['selected'] as List? ?? []).cast<String>();
      final text = value['text'] as String? ?? '';
      if (selected.any((v) => !q.options.contains(v)) ||
          !q.multiple && selected.length > 1) {
        throw StateError('请选择有效选项');
      }
      if (q.required && selected.isEmpty && text.trim().isEmpty) {
        throw StateError('请回答必答问题');
      }
    }
    request.answer.complete({'answers': answers});
  }
}
