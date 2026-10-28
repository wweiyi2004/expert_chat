import '../llm/llm_provider.dart';

const fileEditToolName = 'coding_edit_file';
const _maxEdits = 50;

/// Partial text edit, expanded client-side into one versioned
/// `coding_write_file`, so approval, ownership, diff and undo records all see
/// an ordinary full write.
const fileEditTool = ToolSpec(
  name: fileEditToolName,
  description:
      '局部修改已有 UTF-8 文件：按顺序把 old_string 替换为 new_string，无需重写整个文件。'
      'expected_sha256 必须来自最近一次 coding_read_file；old_string 须与原文逐字一致（含缩进），'
      '且在文件中唯一，否则加入更多上下文或设置 replace_all。新建文件请用 coding_write_file。',
  parameters: {
    'type': 'object',
    'properties': {
      'scope': {'type': 'string'},
      'path': {'type': 'string'},
      'expected_sha256': {'type': 'string'},
      'edits': {
        'type': 'array',
        'minItems': 1,
        'maxItems': _maxEdits,
        'items': {
          'type': 'object',
          'properties': {
            'old_string': {'type': 'string'},
            'new_string': {'type': 'string'},
            'replace_all': {'type': 'boolean'},
          },
          'required': ['old_string', 'new_string'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['path', 'expected_sha256', 'edits'],
    'additionalProperties': false,
  },
);

/// Adds [fileEditTool] when a session can both read and write text files.
List<ToolSpec> withFileEdit(List<ToolSpec> tools) {
  final names = tools.map((tool) => tool.name).toSet();
  if (names.contains(fileEditToolName) ||
      !names.contains('coding_read_file') ||
      !names.contains('coding_write_file')) {
    return tools;
  }
  final read = tools.firstWhere((tool) => tool.name == 'coding_read_file');
  final properties = read.parameters['properties'];
  final scope = properties is Map ? properties['scope'] : null;
  return [
    ...tools,
    if (scope is Map)
      ToolSpec(
        name: fileEditTool.name,
        description: fileEditTool.description,
        parameters: {
          ...fileEditTool.parameters,
          'properties': {
            ...fileEditTool.parameters['properties'] as Map,
            'scope': Map<String, dynamic>.from(scope),
          },
        },
      )
    else
      fileEditTool,
  ];
}

class FileEditException implements Exception {
  const FileEditException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Applies [edits] in order. Each old_string must occur exactly once unless
/// replace_all is set; LF-only snippets also match a CRLF file.
String applyFileEdits(String content, Object? edits) {
  if (edits is! List || edits.isEmpty) {
    throw const FileEditException('edits 必须是非空数组');
  }
  if (edits.length > _maxEdits) {
    throw const FileEditException('edits 最多 $_maxEdits 项，请分多次修改');
  }
  final crlf = content.contains('\r\n');
  var result = content;
  for (var i = 0; i < edits.length; i++) {
    final edit = edits[i];
    final label = '第 ${i + 1} 处修改';
    if (edit is! Map ||
        edit['old_string'] is! String ||
        edit['new_string'] is! String) {
      throw FileEditException('$label：old_string 和 new_string 必须是字符串');
    }
    if (edit.containsKey('replace_all') && edit['replace_all'] is! bool) {
      throw FileEditException('$label：replace_all 必须是布尔值');
    }
    var oldText = edit['old_string'] as String;
    var newText = edit['new_string'] as String;
    if (oldText.isEmpty) {
      throw FileEditException(
        '$label：old_string 不能为空；新建文件请用 coding_write_file',
      );
    }
    if (oldText == newText) {
      throw FileEditException('$label：old_string 与 new_string 相同');
    }
    var count = _occurrences(result, oldText);
    if (count == 0 && crlf && !oldText.contains('\r\n')) {
      final converted = oldText.replaceAll('\n', '\r\n');
      final matches = _occurrences(result, converted);
      if (matches > 0) {
        oldText = converted;
        newText = newText.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
        count = matches;
      }
    }
    if (count == 0) {
      throw FileEditException(
        '$label：在文件中找不到 old_string（须逐字一致，含缩进与空白）。请重新读取文件后再试',
      );
    }
    if (count > 1 && edit['replace_all'] != true) {
      throw FileEditException(
        '$label：old_string 出现 $count 次；请加入更多上下文使其唯一，或设置 replace_all=true',
      );
    }
    result = edit['replace_all'] == true
        ? result.replaceAll(oldText, newText)
        : result.replaceFirst(oldText, newText);
  }
  return result;
}

int _occurrences(String haystack, String needle) {
  var count = 0;
  for (
    var at = haystack.indexOf(needle);
    at >= 0;
    at = haystack.indexOf(needle, at + needle.length)
  ) {
    count++;
  }
  return count;
}
