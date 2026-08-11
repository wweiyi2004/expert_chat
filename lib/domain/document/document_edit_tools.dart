import 'dart:convert';

import '../llm/llm_provider.dart';
import 'document_convert.dart';
import 'document_patch.dart';

/// LLM tools for document edit-and-return (Linux document service).
class DocumentEditTools {
  DocumentEditTools._();

  static const editDocumentToolName = 'edit_document';
  static const convertDocumentToolName = 'convert_document';
  static const inspectDocumentToolName = 'inspect_document';

  static const editDocumentTool = ToolSpec(
    name: editDocumentToolName,
    description:
        '按结构化补丁修改用户本轮上传的可编辑文件，'
        '由客户端提交到 Expert Chat Gateway 并回传可下载的新文件。'
        '支持：.xlsx / .docx / .pptx / .txt / .md / .csv / .tsv。'
        '仅在用户明确要求改文件/导出/回传，或点击「改文档」时必须调用。'
        'patch 必须是完整 DocumentPatch（schema_version=1, format, ops）。'
        'xlsx：set_cells / set_range / add_sheet / ensure_sheet；'
        'docx：replace_text；'
        'pptx：set_shape_text（slide 从 1 起，shape 从 0 起）；'
        'txt/md/csv/tsv：replace_text（查找替换）或 set_text（整文件覆写，text 为完整新内容）。'
        '若附件标注「内容过长，已截断」，禁止 set_text（会丢失未展示部分），只能 replace_text。'
        '不要输出整文件 base64；不要编造未上传的附件。',
    parameters: {
      'type': 'object',
      'properties': {
        'attachment_name': {
          'type': 'string',
          'description': '要修改的附件文件名（含扩展名）。本轮仅一个可编辑文件时可省略。',
        },
        'output_filename': {
          'type': 'string',
          'description': '可选下载文件名（禁止路径分隔符）',
        },
        'patch': {
          'type': 'object',
          'description': 'DocumentPatch v1',
          'properties': {
            'schema_version': {'type': 'integer', 'description': '固定为 1'},
            'format': {
              'type': 'string',
              'enum': ['xlsx', 'docx', 'pptx', 'txt', 'md', 'csv', 'tsv'],
            },
            'output_filename': {'type': 'string'},
            'ops': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'op': {
                    'type': 'string',
                    'enum': [
                      'set_cells',
                      'set_range',
                      'add_sheet',
                      'ensure_sheet',
                      'replace_text',
                      'set_text',
                      'set_shape_text',
                    ],
                  },
                  'sheet': {'type': 'string'},
                  'cells': {'type': 'object', 'additionalProperties': true},
                  'start': {'type': 'string'},
                  'values': {
                    'type': 'array',
                    'items': {'type': 'array'},
                  },
                  'name': {'type': 'string'},
                  'find': {'type': 'string'},
                  'replace': {'type': 'string'},
                  'all': {'type': 'boolean'},
                  'slide': {'type': 'integer'},
                  'shape': {'type': 'integer'},
                  'text': {'type': 'string'},
                },
                'required': ['op'],
              },
            },
          },
          'required': ['schema_version', 'format', 'ops'],
        },
      },
      'required': ['patch'],
    },
  );

  static final convertDocumentTool = ToolSpec(
    name: convertDocumentToolName,
    description:
        '将用户本轮上传的可编辑文件转换为另一种格式，由客户端提交到 Expert Chat Gateway 并回传下载。'
        '在用户要求「转成 / 导出为 / 转换格式」时调用（例如 txt→docx、csv→xlsx、docx→md）。'
        '不要用 edit_document 做跨格式转换。'
        '支持矩阵：${DocumentConvert.matrixSummary()}。'
        '不要输出整文件 base64；不要编造未上传的附件。',
    parameters: {
      'type': 'object',
      'properties': {
        'attachment_name': {
          'type': 'string',
          'description': '源附件文件名（含扩展名）。本轮仅一个可编辑文件时可省略。',
        },
        'target_format': {
          'type': 'string',
          'enum': ['xlsx', 'docx', 'pptx', 'txt', 'md', 'csv', 'tsv'],
          'description': '目标格式（不含点号）',
        },
        'output_filename': {
          'type': 'string',
          'description': '可选下载文件名（禁止路径分隔符）',
        },
      },
      'required': ['target_format'],
    },
  );

  static const inspectDocumentTool = ToolSpec(
    name: inspectDocumentToolName,
    description: '查看本轮上传的可编辑附件结构提示，便于编写 edit_document 补丁。',
    parameters: {
      'type': 'object',
      'properties': {
        'attachment_name': {'type': 'string'},
      },
    },
  );

  static final all = <ToolSpec>[
    editDocumentTool,
    convertDocumentTool,
    inspectDocumentTool,
  ];

  static EditDocumentArgs parseEditDocumentArgs(String argumentsJson) {
    late final Object? decoded;
    try {
      final trimmed = argumentsJson.trim();
      decoded = trimmed.isEmpty ? <String, dynamic>{} : jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw DocumentPatchException(
        'edit_document 参数不是合法 JSON：${e.message}',
        code: 'patch_invalid',
      );
    }
    if (decoded is! Map) {
      throw const DocumentPatchException(
        'edit_document 参数必须是对象',
        code: 'patch_invalid',
      );
    }
    final map = Map<String, dynamic>.from(decoded);
    final attachmentName = map['attachment_name'] ?? map['attachmentName'];
    final outputOverride = map['output_filename'] ?? map['outputFilename'];
    final patchRaw = map['patch'];
    if (patchRaw == null) {
      throw const DocumentPatchException('缺少 patch 字段', code: 'patch_invalid');
    }
    var patch = DocumentPatch.parse(patchRaw);
    if (outputOverride is String && outputOverride.trim().isNotEmpty) {
      final name = outputOverride.trim();
      if (name.contains('/') ||
          name.contains('\\') ||
          name.contains('..') ||
          name.contains('\x00')) {
        throw const DocumentPatchException(
          'output_filename 含非法路径字符',
          code: 'patch_invalid',
        );
      }
      if (name.length > DocumentPatch.maxOutputFilenameLength) {
        throw DocumentPatchException(
          'output_filename 过长（>${DocumentPatch.maxOutputFilenameLength}）',
          code: 'patch_invalid',
        );
      }
      patch = DocumentPatch(
        schemaVersion: patch.schemaVersion,
        format: patch.format,
        ops: patch.ops,
        outputFilename: name,
      );
    }
    return EditDocumentArgs(
      attachmentName:
          attachmentName is String && attachmentName.trim().isNotEmpty
          ? attachmentName.trim()
          : null,
      patch: patch,
    );
  }

  static ConvertDocumentArgs parseConvertDocumentArgs(String argumentsJson) {
    late final Object? decoded;
    try {
      final trimmed = argumentsJson.trim();
      decoded = trimmed.isEmpty ? <String, dynamic>{} : jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw DocumentPatchException(
        'convert_document 参数不是合法 JSON：${e.message}',
        code: 'patch_invalid',
      );
    }
    if (decoded is! Map) {
      throw const DocumentPatchException(
        'convert_document 参数必须是对象',
        code: 'patch_invalid',
      );
    }
    final map = Map<String, dynamic>.from(decoded);
    final attachmentName = map['attachment_name'] ?? map['attachmentName'];
    final targetRaw =
        map['target_format'] ?? map['targetFormat'] ?? map['format'];
    if (targetRaw is! String || targetRaw.trim().isEmpty) {
      throw const DocumentPatchException(
        '缺少 target_format',
        code: 'patch_invalid',
      );
    }
    var target = targetRaw.trim().toLowerCase();
    if (target.startsWith('.')) target = target.substring(1);
    if (!DocumentConvert.supportedFormats.contains(target)) {
      throw DocumentPatchException(
        '不支持的 target_format="$target"',
        code: 'unsupported_format',
      );
    }
    String? outputFilename;
    final outRaw = map['output_filename'] ?? map['outputFilename'];
    if (outRaw is String && outRaw.trim().isNotEmpty) {
      final name = outRaw.trim();
      if (name.contains('/') ||
          name.contains('\\') ||
          name.contains('..') ||
          name.contains('\x00')) {
        throw const DocumentPatchException(
          'output_filename 含非法路径字符',
          code: 'patch_invalid',
        );
      }
      if (name.length > DocumentPatch.maxOutputFilenameLength) {
        throw DocumentPatchException(
          'output_filename 过长（>${DocumentPatch.maxOutputFilenameLength}）',
          code: 'patch_invalid',
        );
      }
      outputFilename = name;
    }
    return ConvertDocumentArgs(
      attachmentName:
          attachmentName is String && attachmentName.trim().isNotEmpty
          ? attachmentName.trim()
          : null,
      targetFormat: target,
      outputFilename: outputFilename,
    );
  }
}

class EditDocumentArgs {
  const EditDocumentArgs({required this.patch, this.attachmentName});

  final String? attachmentName;
  final DocumentPatch patch;
}

class ConvertDocumentArgs {
  const ConvertDocumentArgs({
    required this.targetFormat,
    this.attachmentName,
    this.outputFilename,
  });

  final String? attachmentName;
  final String targetFormat;
  final String? outputFilename;
}
