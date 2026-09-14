/// Explicit archive migrations. Unknown columns/tables are never discarded to
/// make a backup appear compatible. Normal validation still runs afterwards.
class BackupMigrations {
  static const currentSchema = 16;
  static const supportedSchemas = {15, 16};
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

    final tables = payload['tables'];
    if (tables is! Map<String, dynamic> ||
        tables.length != _v15Tables.length ||
        !tables.keys.every(_v15Tables.contains)) {
      throw const FormatException('旧版备份的数据表不完整或含未知数据，未执行转换。');
    }
    final conversations = tables['conversations'];
    if (conversations is! List) throw const FormatException('旧版会话表格式错误。');
    final migratedConversations = <Map<String, dynamic>>[];
    for (final row in conversations) {
      if (row is! Map<String, dynamic> || row.containsKey('project_id')) {
        throw const FormatException('旧版会话含不兼容字段，未执行转换。');
      }
      migratedConversations.add({...row, 'project_id': null});
    }
    return {
      ...payload,
      'schemaVersion': targetSchema,
      'tables': {
        ...tables,
        'conversations': migratedConversations,
        'projects': <dynamic>[],
        'project_files': <dynamic>[],
        'generation_records': <dynamic>[],
      },
    };
  }
}
