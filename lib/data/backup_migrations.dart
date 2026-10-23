/// Explicit archive migrations. Unknown columns/tables are never discarded to
/// make a backup appear compatible. Normal validation still runs afterwards.
class BackupMigrations {
  static const currentSchema = 17;
  static const supportedSchemas = {15, 16, 17};
  static const _v15Tables = {
    'character_cards',
    'world_info_entries',
    'library_items',
    'conversations',
    'messages',
    'study_entities',
    'study_sessions',
  };

  static Map<String, dynamic> upgrade(
    Map<String, dynamic> payload, {
    required int targetSchema,
  }) {
    final source = payload['schemaVersion'];
    if (source is! int || source < 1) {
      throw const FormatException('备份缺少有效的数据版本。');
    }
    if (source > targetSchema) {
      throw const FormatException('备份来自更新的数据版本，请先升级应用再恢复。');
    }
    if (targetSchema != currentSchema) {
      throw const FormatException('当前应用尚未配置这一路径的备份转换。');
    }
    if (!supportedSchemas.contains(source)) {
      throw const FormatException('暂不支持此旧版完整备份，请先在兼容版本中重新导出。');
    }
    if (source == targetSchema) return payload;

    var tables = payload['tables'];
    final expectedTables = source == 15
        ? _v15Tables
        : {..._v15Tables, 'projects', 'project_files', 'generation_records'};
    if (tables is! Map<String, dynamic> ||
        tables.length != expectedTables.length ||
        !tables.keys.every(expectedTables.contains)) {
      throw const FormatException('旧版备份的数据表不完整或含未知数据，未执行转换。');
    }
    if (source == 15) {
      final conversations = tables['conversations'];
      if (conversations is! List) throw const FormatException('旧版会话表格式错误。');
      final migratedConversations = <Map<String, dynamic>>[];
      for (final row in conversations) {
        if (row is! Map<String, dynamic> || row.containsKey('project_id')) {
          throw const FormatException('旧版会话含不兼容字段，未执行转换。');
        }
        migratedConversations.add({...row, 'project_id': null});
      }
      tables = {
        ...tables,
        'conversations': migratedConversations,
        'projects': <dynamic>[],
        'project_files': <dynamic>[],
        'generation_records': <dynamic>[],
      };
    }
    final generations = tables['generation_records'];
    if (generations is! List) throw const FormatException('旧版生图记录表格式错误。');
    final migratedGenerations = <Map<String, dynamic>>[];
    for (final row in generations) {
      if (row is! Map<String, dynamic> || row.containsKey('api_format')) {
        throw const FormatException('旧版生图记录含不兼容字段，未执行转换。');
      }
      migratedGenerations.add({...row, 'api_format': null});
    }
    return {
      ...payload,
      'schemaVersion': targetSchema,
      'tables': {...tables, 'generation_records': migratedGenerations},
    };
  }
}
