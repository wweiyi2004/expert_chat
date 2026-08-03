import 'dart:convert';

/// Wire format for document edits shared by the App (LLM tools + client
/// validation) and the Linux document service.
///
/// See `docs/document-edit-contract.md`.
class DocumentPatch {
  const DocumentPatch({
    required this.format,
    required this.ops,
    this.schemaVersion = currentSchemaVersion,
    this.outputFilename,
  });

  static const currentSchemaVersion = 1;
  static const maxOps = 200;
  static const maxCellsPerOp = 5000;
  static const maxOutputFilenameLength = 180;

  /// Formats the App + Linux service implement.
  static const supportedFormats = {'xlsx', 'docx', 'pptx'};

  /// @Deprecated Keep alias for older call sites / tests.
  static const p0Formats = supportedFormats;

  final int schemaVersion;
  final String format;
  final List<DocumentOp> ops;
  final String? outputFilename;

  bool get isSupportedFormat => supportedFormats.contains(format);
  bool get isP0Format => isSupportedFormat;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'format': format,
    'ops': [for (final op in ops) op.toJson()],
    if (outputFilename != null && outputFilename!.isNotEmpty)
      'output_filename': outputFilename,
  };

  String toJsonString({bool pretty = false}) =>
      pretty ? const JsonEncoder.withIndent('  ').convert(toJson()) : jsonEncode(toJson());

  /// Parses and validates. Throws [DocumentPatchException] on any violation.
  ///
  /// [p0Only] is ignored (kept for API stability); xlsx/docx/pptx are all
  /// accepted when listed in [supportedFormats].
  factory DocumentPatch.parse(Object? raw, {bool p0Only = true}) {
    final map = _asObject(raw, path: r'$');
    final version = _asInt(map['schema_version'], path: 'schema_version');
    if (version != currentSchemaVersion) {
      throw DocumentPatchException(
        '不支持的 schema_version=$version（需要 $currentSchemaVersion）',
        code: 'patch_invalid',
      );
    }
    final format = _asString(map['format'], path: 'format').toLowerCase();
    if (!supportedFormats.contains(format)) {
      throw DocumentPatchException(
        '不支持的 format="$format"',
        code: 'unsupported_format',
      );
    }

    final opsRaw = map['ops'];
    if (opsRaw is! List) {
      throw DocumentPatchException('ops 必须是数组', code: 'patch_invalid');
    }
    if (opsRaw.isEmpty) {
      throw DocumentPatchException('ops 不能为空', code: 'patch_invalid');
    }
    if (opsRaw.length > maxOps) {
      throw DocumentPatchException(
        'ops 超过上限 $maxOps（实际 ${opsRaw.length}）',
        code: 'patch_invalid',
      );
    }

    final ops = <DocumentOp>[];
    for (var i = 0; i < opsRaw.length; i++) {
      ops.add(DocumentOp.parse(opsRaw[i], path: 'ops[$i]', format: format));
    }

    final outName = map['output_filename'] ?? map['outputFilename'];
    String? outputFilename;
    if (outName != null) {
      outputFilename = _sanitizeOutputFilename(_asString(outName, path: 'output_filename'));
    }

    return DocumentPatch(
      schemaVersion: version,
      format: format,
      ops: List.unmodifiable(ops),
      outputFilename: outputFilename,
    );
  }

  /// Convenience: parse a JSON string from the model or multipart field.
  factory DocumentPatch.parseJson(String raw, {bool p0Only = true}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const DocumentPatchException('patch JSON 为空', code: 'patch_invalid');
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw DocumentPatchException(
        'patch 不是合法 JSON：${e.message}',
        code: 'patch_invalid',
      );
    }
    return DocumentPatch.parse(decoded, p0Only: p0Only);
  }

  static String _sanitizeOutputFilename(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const DocumentPatchException(
        'output_filename 不能为空',
        code: 'patch_invalid',
      );
    }
    if (trimmed.length > maxOutputFilenameLength) {
      throw DocumentPatchException(
        'output_filename 过长（>$maxOutputFilenameLength）',
        code: 'patch_invalid',
      );
    }
    if (trimmed.contains('/') ||
        trimmed.contains('\\') ||
        trimmed.contains('..') ||
        trimmed.contains('\x00')) {
      throw const DocumentPatchException(
        'output_filename 含非法路径字符',
        code: 'patch_invalid',
      );
    }
    return trimmed;
  }
}

/// One deterministic edit operation.
sealed class DocumentOp {
  const DocumentOp();

  String get op;
  Map<String, dynamic> toJson();

  factory DocumentOp.parse(
    Object? raw, {
    required String path,
    required String format,
  }) {
    final map = _asObject(raw, path: path);
    final kind = _asString(map['op'], path: '$path.op').toLowerCase();
    switch (kind) {
      case 'set_cells':
        return SetCellsOp.parse(map, path: path);
      case 'set_range':
        return SetRangeOp.parse(map, path: path);
      case 'add_sheet':
        return AddSheetOp.parse(map, path: path, ensureOnly: false);
      case 'ensure_sheet':
        return AddSheetOp.parse(map, path: path, ensureOnly: true);
      case 'replace_text':
        return ReplaceTextOp.parse(map, path: path);
      case 'set_shape_text':
        return SetShapeTextOp.parse(map, path: path);
      default:
        throw DocumentPatchException(
          '未知 op="$kind"（$path）',
          code: 'patch_invalid',
        );
    }
  }
}

/// Word: replace all occurrences of [find] with [replace] in the document.
class ReplaceTextOp extends DocumentOp {
  const ReplaceTextOp({
    required this.find,
    required this.replace,
    this.all = true,
  });

  final String find;
  final String replace;
  final bool all;

  @override
  String get op => 'replace_text';

  @override
  Map<String, dynamic> toJson() => {
    'op': op,
    'find': find,
    'replace': replace,
    'all': all,
  };

  factory ReplaceTextOp.parse(Map<String, dynamic> map, {required String path}) {
    final find = _asString(map['find'], path: '$path.find');
    if (find.isEmpty) {
      throw DocumentPatchException('$path.find 不能为空', code: 'patch_invalid');
    }
    final replace = map['replace'];
    final replaceStr = replace == null ? '' : replace.toString();
    final all = map['all'] is bool ? map['all'] as bool : true;
    return ReplaceTextOp(find: find, replace: replaceStr, all: all);
  }
}

/// PowerPoint: set text on a shape. [slide] is 1-based; [shape] is 0-based
/// index among shapes that have a text frame (server resolves).
class SetShapeTextOp extends DocumentOp {
  const SetShapeTextOp({
    required this.slide,
    required this.text,
    this.shape = 0,
  });

  final int slide;
  final int shape;
  final String text;

  @override
  String get op => 'set_shape_text';

  @override
  Map<String, dynamic> toJson() => {
    'op': op,
    'slide': slide,
    'shape': shape,
    'text': text,
  };

  factory SetShapeTextOp.parse(Map<String, dynamic> map, {required String path}) {
    final slide = _asInt(map['slide'] ?? 1, path: '$path.slide');
    if (slide < 1) {
      throw DocumentPatchException('$path.slide 必须 ≥ 1', code: 'patch_invalid');
    }
    final shape = map['shape'] == null
        ? 0
        : _asInt(map['shape'], path: '$path.shape');
    if (shape < 0) {
      throw DocumentPatchException('$path.shape 必须 ≥ 0', code: 'patch_invalid');
    }
    final text = map['text'];
    final textStr = text == null ? '' : text.toString();
    return SetShapeTextOp(slide: slide, shape: shape, text: textStr);
  }
}

/// Set individual A1-addressed cells on a sheet.
class SetCellsOp extends DocumentOp {
  const SetCellsOp({required this.cells, this.sheet});

  final String? sheet;
  final Map<String, Object?> cells;

  @override
  String get op => 'set_cells';

  @override
  Map<String, dynamic> toJson() => {
    'op': op,
    if (sheet != null && sheet!.isNotEmpty) 'sheet': sheet,
    'cells': cells,
  };

  factory SetCellsOp.parse(Map<String, dynamic> map, {required String path}) {
    final sheet = _optionalSheet(map, path: path);
    final cellsRaw = map['cells'];
    if (cellsRaw is! Map) {
      throw DocumentPatchException(
        '$path.cells 必须是对象',
        code: 'patch_invalid',
      );
    }
    if (cellsRaw.isEmpty) {
      throw DocumentPatchException(
        '$path.cells 不能为空',
        code: 'patch_invalid',
      );
    }
    if (cellsRaw.length > DocumentPatch.maxCellsPerOp) {
      throw DocumentPatchException(
        '$path.cells 超过 ${DocumentPatch.maxCellsPerOp} 个',
        code: 'patch_invalid',
      );
    }
    final cells = <String, Object?>{};
    for (final entry in cellsRaw.entries) {
      final addr = entry.key.toString().trim().toUpperCase();
      if (!_isA1Address(addr)) {
        throw DocumentPatchException(
          '$path.cells 含非法地址 "${entry.key}"',
          code: 'patch_invalid',
        );
      }
      cells[addr] = _cellValue(entry.value, path: '$path.cells.$addr');
    }
    return SetCellsOp(sheet: sheet, cells: Map.unmodifiable(cells));
  }
}

/// Write a 2D block starting at [start] (A1).
class SetRangeOp extends DocumentOp {
  const SetRangeOp({
    required this.start,
    required this.values,
    this.sheet,
  });

  final String? sheet;
  final String start;
  final List<List<Object?>> values;

  @override
  String get op => 'set_range';

  @override
  Map<String, dynamic> toJson() => {
    'op': op,
    if (sheet != null && sheet!.isNotEmpty) 'sheet': sheet,
    'start': start,
    'values': values,
  };

  factory SetRangeOp.parse(Map<String, dynamic> map, {required String path}) {
    final sheet = _optionalSheet(map, path: path);
    final start = _asString(map['start'], path: '$path.start').trim().toUpperCase();
    if (!_isA1Address(start)) {
      throw DocumentPatchException(
        '$path.start 不是合法 A1 地址: "$start"',
        code: 'patch_invalid',
      );
    }
    final valuesRaw = map['values'];
    if (valuesRaw is! List || valuesRaw.isEmpty) {
      throw DocumentPatchException(
        '$path.values 必须是非空二维数组',
        code: 'patch_invalid',
      );
    }
    final values = <List<Object?>>[];
    var cellCount = 0;
    for (var r = 0; r < valuesRaw.length; r++) {
      final rowRaw = valuesRaw[r];
      if (rowRaw is! List) {
        throw DocumentPatchException(
          '$path.values[$r] 必须是数组',
          code: 'patch_invalid',
        );
      }
      final row = <Object?>[];
      for (var c = 0; c < rowRaw.length; c++) {
        cellCount++;
        if (cellCount > DocumentPatch.maxCellsPerOp) {
          throw DocumentPatchException(
            '$path.values 单元格超过 ${DocumentPatch.maxCellsPerOp}',
            code: 'patch_invalid',
          );
        }
        row.add(_cellValue(rowRaw[c], path: '$path.values[$r][$c]'));
      }
      values.add(List.unmodifiable(row));
    }
    return SetRangeOp(
      sheet: sheet,
      start: start,
      values: List.unmodifiable(values),
    );
  }
}

/// Create a worksheet. [ensureOnly] true → skip if exists; false → error if exists.
class AddSheetOp extends DocumentOp {
  const AddSheetOp({required this.name, this.ensureOnly = false});

  final String name;
  final bool ensureOnly;

  @override
  String get op => ensureOnly ? 'ensure_sheet' : 'add_sheet';

  @override
  Map<String, dynamic> toJson() => {
    'op': op,
    'name': name,
  };

  factory AddSheetOp.parse(
    Map<String, dynamic> map, {
    required String path,
    required bool ensureOnly,
  }) {
    final name = _asString(map['name'], path: '$path.name').trim();
    if (name.isEmpty) {
      throw DocumentPatchException(
        '$path.name 不能为空',
        code: 'patch_invalid',
      );
    }
    if (name.length > 31) {
      throw DocumentPatchException(
        '$path.name 超过 Excel 31 字符限制',
        code: 'patch_invalid',
      );
    }
    if (RegExp(r'[\\/*?:\[\]]').hasMatch(name)) {
      throw DocumentPatchException(
        '$path.name 含 Excel 非法字符',
        code: 'patch_invalid',
      );
    }
    return AddSheetOp(name: name, ensureOnly: ensureOnly);
  }
}

class DocumentPatchException implements Exception {
  const DocumentPatchException(this.message, {this.code = 'patch_invalid'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

// --- parsing helpers ---

Map<String, dynamic> _asObject(Object? raw, {required String path}) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  throw DocumentPatchException('$path 必须是对象', code: 'patch_invalid');
}

String _asString(Object? raw, {required String path}) {
  if (raw is String && raw.trim().isNotEmpty) return raw.trim();
  if (raw is String) {
    throw DocumentPatchException('$path 不能为空', code: 'patch_invalid');
  }
  throw DocumentPatchException('$path 必须是字符串', code: 'patch_invalid');
}

int _asInt(Object? raw, {required String path}) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  throw DocumentPatchException('$path 必须是整数', code: 'patch_invalid');
}

String? _optionalSheet(Map<String, dynamic> map, {required String path}) {
  final sheet = map['sheet'];
  if (sheet == null) return null;
  final s = _asString(sheet, path: '$path.sheet');
  return s.isEmpty ? null : s;
}

Object? _cellValue(Object? raw, {required String path}) {
  if (raw == null) return null;
  if (raw is bool || raw is num || raw is String) return raw;
  throw DocumentPatchException(
    '$path 单元格值类型无效（仅 null/bool/number/string）',
    code: 'patch_invalid',
  );
}

/// Basic A1 / A1-style single cell (no ranges like A1:B2).
bool _isA1Address(String value) {
  return RegExp(r'^[A-Z]{1,3}[1-9][0-9]{0,6}$').hasMatch(value);
}
