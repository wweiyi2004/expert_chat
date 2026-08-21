import 'dart:convert';

import '../../data/models.dart';
import '../llm/llm_provider.dart';

/// Client-side vision: the chat model never receives pixels. It calls this
/// tool, and the controller forwards the image to the configured vision API.
class VisionTools {
  static const analyzeImageToolName = 'analyze_image';

  static const analyzeImageTool = ToolSpec(
    name: analyzeImageToolName,
    description:
        '用独立视觉模型查看用户上传的图片，返回文字观察（描述、OCR、细节问答）。'
        '对话模型看不到像素；只要回答依赖图中内容就必须调用本工具。'
        'attachment_name 填【图片：文件名】里的名字；省略则分析本轮最新一张。'
        'question 用于聚焦，例如「图中文字是什么」「右上角的标志」。',
    parameters: {
      'type': 'object',
      'properties': {
        'attachment_name': {
          'type': 'string',
          'description': '要查看的附件文件名。省略则使用本轮最新图片。',
        },
        'question': {
          'type': 'string',
          'description': '想从图中弄清的问题。可省略，默认描述关键信息并转录可见文字。',
        },
      },
    },
  );

  static const defaultQuestion = '请描述这张图片的关键信息，并转录图中可见文字。';

  static AnalyzeImageArgs parseArgs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final name =
            decoded['attachment_name'] ??
            decoded['filename'] ??
            decoded['name'];
        final question =
            decoded['question'] ?? decoded['prompt'] ?? decoded['query'];
        return AnalyzeImageArgs(
          attachmentName: name is String ? name.trim() : '',
          question: question is String ? question.trim() : '',
        );
      }
    } catch (_) {
      // Malformed JSON from the model.
    }
    return const AnalyzeImageArgs();
  }

  static Attachment? pickImage(
    List<Attachment> sources,
    String? attachmentName,
  ) {
    final images = [
      for (final a in sources)
        if (a.isImage && a.hasImageData) a,
    ];
    if (images.isEmpty) return null;
    final want = attachmentName?.trim() ?? '';
    if (want.isEmpty) return images.last;
    for (final a in images) {
      if (a.name == want || a.name.toLowerCase() == want.toLowerCase()) {
        return a;
      }
    }
    return null;
  }

  static String availableNames(List<Attachment> sources) {
    final names = [
      for (final a in sources)
        if (a.isImage && a.hasImageData) a.name,
    ];
    return names.isEmpty ? '（没有可识图附件）' : names.join('、');
  }
}

class AnalyzeImageArgs {
  const AnalyzeImageArgs({this.attachmentName = '', this.question = ''});

  final String attachmentName;
  final String question;

  String get resolvedQuestion =>
      question.trim().isEmpty ? VisionTools.defaultQuestion : question.trim();
}
