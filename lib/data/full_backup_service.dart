import 'task_data_backup.dart';
import 'capability_settings_bundle.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../platform/foundation.dart' show compute;
import '../platform/preferences.dart';
import 'package:uuid/uuid.dart';
import '../domain/memory/memory_codec.dart';
import 'backup_codec.dart';
import 'backup_migrations.dart';
import 'backup_journal.dart';
import 'db/app_database.dart';
import 'library_file_store.dart';
import 'library_paths.dart';
import 'learning_plan.dart';
import 'memory_repository.dart';
import 'models.dart' show kCheckpointEnd;

/// Restore is additive. Existing database rows/files are never overwritten.
/// Memory/preferences are covered by a durable undo journal and a SQL commit
/// marker. Call recoverPending before starting controllers on every launch.
class FullBackupService {
  FullBackupService(this.db, this.files, this.memory, this.prefs, this.journal);
  final AppDatabase db;
  final LibraryFileStore files;
  final MemoryStore memory;
  final SharedPreferences prefs;
  final BackupJournal journal;
  bool _busy = false;
  static const _uuid = Uuid();
  static const _codec = MemoryMarkdownCodec();
  static const maxRecords = 100000;
  static const tableNames = [
    'projects',
    'character_cards',
    'world_info_entries',
    'library_items',
    'conversations',
    'messages',
    'study_entities',
    'study_sessions',
    'project_files',
    'generation_records',
  ];

  /// Explicit allowlist: never read secure storage, endpoints, profiles,
  /// terminal credentials, gateway config, tokens or usage/cache records.
  static const preferenceKeys = {
    ...CapabilitySettingsBundle.keys,
    'themeMode',
    'uiPrefs',
    'contextPrefs',
    'modelContextPrefs',
    'workAgentLimits.v1',
    'workAgentModelPool.v1',
    'taskBudget',
    'searchMaxRounds',
    'searchMaxResults',
    'composerSearchMode',
    'composerImageGenMode',
    'reasoningEffort',
    'systemPrompt',
    'workAgentInstructions',
    'subagentInstructions',
    'subagentRoles.v1',
    'subagentRouterModel',
    'chatSkills',
    'tuiSchedules.v1',
    'tuiUpdateManifestUrl',
    'promptPresetsV1',
    'memoryEnabled',
    'studyModeEnabled',
    'creationModeEnabled',
  };

  // Retain the v17 wire location for compatibility with existing backups.
  // Learning plans are business data, not optional/replaceable preferences.
  static const _learningPlansKey = 'learningPlansV1';
  static const _workMemoryKey = 'workMemory.v1';
  static const _storedKeys = {
    ...preferenceKeys,
    _learningPlansKey,
    _workMemoryKey,
    ...TaskDataBackup.keys,
  };

  Future<Uint8List> exportBackup() => _exclusive(() async {
    if (await journal.read() != null) throw StateError('请先重启应用完成恢复检查。');
    _learningPlanRows(prefs.getString(_learningPlansKey));
    final tables = <String, dynamic>{};
    await db.transaction(() async {
      var approximateBytes = 0;
      var rowCount = 0;
      for (final name in tableNames) {
        final rows = await db.customSelect('SELECT * FROM "$name"').get();
        rowCount += rows.length;
        _checkRecordCount(rowCount);
        tables[name] = [for (final row in rows) row.data];
        approximateBytes += utf8.encode(jsonEncode(tables[name])).length;
        if (approximateBytes > BackupCodec.maxBytes) {
          throw const FormatException('会话数据超过 128 MB 备份上限。');
        }
      }
    });
    final blobs = <String, dynamic>{};
    var totalBytes = utf8.encode(jsonEncode(tables)).length;
    for (final row in tables['library_items'] as List) {
      final bytes = await files.readBytes(row['relative_path'] as String);
      if (bytes == null ||
          bytes.length != row['size_bytes'] ||
          sha256.convert(bytes).toString() != row['sha256']) {
        throw FormatException('素材缺失或已被外部修改：${row['name']}。未生成不完整备份。');
      }
      totalBytes += ((bytes.length + 2) ~/ 3) * 4;
      if (totalBytes > BackupCodec.maxBytes) {
        throw const FormatException('含素材的备份超过 128 MB 上限。');
      }
      blobs[row['id'] as String] = base64Encode(bytes);
    }
    final workMemory = _workMemoryRows(prefs.getString(_workMemoryKey));
    final capabilityValues =
        CapabilitySettingsBundle.read(prefs)['values'] as Map;
    final conversationIds = (tables['conversations'] as List)
        .map((row) => row['id'])
        .toSet();
    final taskPreferences = TaskDataBackup.exportValues({
      for (final key in TaskDataBackup.keys) key: prefs.get(key),
    }, conversationIds);
    _checkRecordCount(
      tables.values.fold<int>(0, (sum, rows) => sum + (rows as List).length) +
          TaskDataBackup.recordCount(taskPreferences),
    );
    return compute(BackupCodec.encode, {
      'version': BackupCodec.version,
      'schemaVersion': db.schemaVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tables': tables,
      'files': blobs,
      'memory': await memory.read() ?? '',
      'preferences': {
        ...taskPreferences,
        for (final key in _storedKeys)
          if (prefs.containsKey(key) &&
              key != _workMemoryKey &&
              !TaskDataBackup.keys.contains(key) &&
              !CapabilitySettingsBundle.keys.contains(key))
            key: prefs.get(key),
        for (final entry in capabilityValues.entries)
          entry.key as String: jsonEncode(entry.value),
        if (prefs.containsKey(_workMemoryKey))
          _workMemoryKey: jsonEncode({
            for (final entry in workMemory.entries)
              if (conversationIds.contains(entry.key)) entry.key: entry.value,
          }),
      },
    });
  });

  Future<BackupPreview> preview(Uint8List bytes) async {
    final decoded = await compute(BackupCodec.decode, bytes);
    final payload = BackupMigrations.upgrade(
      decoded,
      targetSchema: db.schemaVersion,
    );
    await _validate(payload);
    return BackupPreview._(payload, decoded['schemaVersion'] as int);
  }

  Future<void> _validate(Map<String, dynamic> payload) async {
    const fields = {
      'version',
      'schemaVersion',
      'createdAt',
      'tables',
      'files',
      'memory',
      'preferences',
    };
    if (!payload.keys.every(fields.contains)) {
      throw const FormatException('备份包含当前版本无法识别的字段，未执行导入。');
    }
    if (payload['schemaVersion'] != db.schemaVersion) {
      throw const FormatException('数据库版本不兼容，请在相同数据版本的应用中恢复。');
    }
    if (payload['createdAt'] != null && payload['createdAt'] is! String) {
      throw const FormatException('备份创建时间格式错误。');
    }
    final tables = payload['tables'];
    final blobs = payload['files'];
    final preferences = payload['preferences'];
    if (tables is! Map<String, dynamic> ||
        blobs is! Map<String, dynamic> ||
        preferences is! Map<String, dynamic> ||
        payload['memory'] is! String ||
        tables.length != tableNames.length ||
        !tables.keys.every(tableNames.contains) ||
        !preferences.keys.every(_storedKeys.contains)) {
      throw const FormatException('备份目录或设置字段不合法。');
    }
    var rowCount = 0;
    for (final name in tableNames) {
      final table = db.allTables.firstWhere((t) => t.actualTableName == name);
      final schema = await db.customSelect('PRAGMA table_info("$name")').get();
      final columns = {for (final c in table.$columns) c.$name};
      final rows = tables[name];
      if (rows is! List) throw const FormatException('备份数据表格式错误。');
      rowCount += rows.length;
      _checkRecordCount(rowCount);
      final keys = <String>{};
      for (final row in rows) {
        if (row is! Map<String, dynamic> ||
            row.length != columns.length ||
            !row.keys.every(columns.contains) ||
            !row.values.every((v) => v == null || v is String || v is num)) {
          throw FormatException('备份表 $name 的字段不合法。');
        }
        final primary = [for (final c in table.$primaryKey) row[c.$name]];
        for (final column in schema) {
          final value = row[column.read<String>('name')];
          final type = column.read<String>('type');
          if ((value == null && column.read<int>('notnull') == 1) ||
              (value != null && type == 'TEXT' && value is! String) ||
              (value != null && type == 'INTEGER' && value is! int)) {
            throw FormatException('备份表 $name 包含无效字段类型。');
          }
        }
        if (primary.any((v) => v is! String || v.isEmpty) ||
            !keys.add(jsonEncode(primary))) {
          throw FormatException('备份表 $name 含无效或重复 ID。');
        }
        for (final entry in row.entries) {
          if (entry.key.endsWith('_json') && entry.value != null) {
            final decoded = jsonDecode(entry.value as String);
            final object = {
              'active_children_json',
              'long_task_json',
              'turn_skill_json',
              'payload_json',
            }.contains(entry.key);
            if (object ? decoded is! Map : decoded is! List) {
              throw FormatException('备份字段 ${entry.key} 的 JSON 类型错误。');
            }
          }
        }
      }
    }
    final messages = {
      for (final row in tables['messages'] as List) row['id']: row,
    };
    final visited = <String>{};
    for (final row in messages.values) {
      final chain = <String>{};
      dynamic cursor = row;
      while (cursor != null && !visited.contains(cursor['id'])) {
        if (!chain.add(cursor['id'] as String)) {
          throw const FormatException('备份消息分支包含循环。');
        }
        final parentId = cursor['parent_id'];
        final parent = parentId == null ? null : messages[parentId];
        if (parentId != null &&
            (parent == null || parent['convo_id'] != cursor['convo_id'])) {
          throw const FormatException('备份消息的父分支不存在或属于其他会话。');
        }
        cursor = parent;
      }
      visited.addAll(chain);
    }
    final library = tables['library_items'] as List;
    if (library.length != blobs.length) throw const FormatException('素材清单不匹配。');
    for (final row in library) {
      final encoded = blobs[row['id']];
      if (encoded is! String) throw const FormatException('缺少素材内容。');
      final content = base64Decode(encoded);
      if (row['size_bytes'] != content.length ||
          row['sha256'] != sha256.convert(content).toString()) {
        throw const FormatException('素材完整性校验失败。');
      }
    }
    if (!preferences.values.every(
      (v) => v is String || v is bool || v is num,
    )) {
      throw const FormatException('偏好设置格式错误。');
    }
    for (final e in preferences.entries) {
      final expectsBool = e.key.endsWith('Enabled');
      final expectsInt = {
        'themeMode',
        'searchMaxRounds',
        'searchMaxResults',
      }.contains(e.key);
      if (expectsBool
          ? e.value is! bool
          : expectsInt
          ? e.value is! int
          : e.value is! String) {
        throw FormatException('偏好设置 ${e.key} 的类型错误。');
      }
    }
    _learningPlanRows(preferences[_learningPlansKey]);
    CapabilitySettingsBundle.validate({
      'version': 1,
      'values': {
        for (final key in CapabilitySettingsBundle.keys)
          if (preferences.containsKey(key))
            key: jsonDecode(preferences[key] as String),
      },
    });

    final workMemory = _workMemoryRows(preferences[_workMemoryKey]);
    final conversationIds = (tables['conversations'] as List)
        .map((row) => row['id'])
        .toSet();
    TaskDataBackup.validateAssociations(preferences, conversationIds);
    _checkRecordCount(rowCount + TaskDataBackup.recordCount(preferences));
    if (!workMemory.keys.every(conversationIds.contains)) {
      throw const FormatException('工作记忆引用了备份中不存在的会话');
    }
  }

  static Map<String, Map<String, dynamic>> _workMemoryRows(
    Object? raw, {
    bool allowAgents = true,
  }) {
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw as String) as Map;
      _checkRecordCount(decoded.length);
      final result = <String, Map<String, dynamic>>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! Map) {
          throw const FormatException();
        }
        final value = Map<String, dynamic>.from(entry.value as Map);
        const textKeys = {
          'constraints',
          'plan',
          'summary',
          'user_pins',
          'updated_at',
        };
        if (!value.keys.every(
          {
            ...textKeys,
            'revision',
            'compact_revision',
            if (allowAgents) 'agents',
          }.contains,
        )) {
          throw const FormatException();
        }
        for (final key in textKeys) {
          if (value[key] != null &&
              (value[key] is! String ||
                  (value[key] as String).length > 24000)) {
            throw const FormatException();
          }
        }
        if (value['revision'] != null &&
            (value['revision'] is! int || (value['revision'] as int) < 0)) {
          throw const FormatException();
        }
        // Export only public notes/pins; active compaction/replay state is local.
        result[entry.key as String] = {
          if (allowAgents && value['agents'] != null)
            'agents': _workMemoryRows(
              jsonEncode(value['agents']),
              allowAgents: false,
            ),
          for (final key in {...textKeys, 'revision'})
            if (value.containsKey(key)) key: value[key],
        };
      }
      return result;
    } catch (_) {
      throw const FormatException('工作记忆格式错误；未覆盖现有用户约束');
    }
  }

  static List<Map<String, dynamic>> _learningPlanRows(Object? raw) {
    if (raw == null) return [];
    try {
      final rows = (jsonDecode(raw as String) as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      _checkRecordCount(rows.length);
      final ids = <String>{};
      for (final row in rows) {
        final plan = LearningPlan.fromJson(row);
        // Fully traverse nested records, including lazily cast ID lists.
        jsonEncode(plan.toJson());
        if (plan.id.isEmpty || !ids.add(plan.id)) {
          throw const FormatException('学习档案 ID 无效或重复');
        }
      }
      return rows;
    } catch (_) {
      throw const FormatException('学习档案格式错误，未覆盖原有记录。');
    }
  }

  Future<void> restoreCopies(
    BackupPreview preview, {
    bool restorePreferences = false,
  }) => _exclusive(() async {
    final payload = preview._payload;
    await _validate(payload);
    if (await journal.read() != null) throw StateError('请先重启应用处理上次恢复。');
    final idMap = <String, String>{};
    String remap(String id) => idMap.putIfAbsent(id, _uuid.v4);
    final tables = <String, List<Map<String, dynamic>>>{};
    for (final name in tableNames) {
      tables[name] = [
        for (final row in payload['tables'][name] as List)
          Map<String, dynamic>.from(row as Map),
      ];
    }
    final stagedPaths = <String>[];
    final fileJobs = <({String id, String name, bool image, String encoded})>[];
    for (final row in tables['library_items']!) {
      final oldId = row['id'] as String;
      final id = remap(oldId);
      final name = row['name'] as String;
      final image = row['kind'] == 'image';
      row['relative_path'] = libraryRelativePath(id, name, image);
      stagedPaths.add(row['relative_path'] as String);
      fileJobs.add((
        id: id,
        name: name,
        image: image,
        encoded: payload['files'][oldId] as String,
      ));
    }
    for (final entry in tables.entries) {
      for (final row in entry.value) {
        for (final key in row.keys.toList()) {
          final value = row[key];
          if (value == null) continue;
          if (key == 'id' || key.endsWith('_id')) {
            row[key] = remap(value as String);
          } else if (key.endsWith('_json')) {
            if (key == 'custom_mcp_server_ids_json') {
              row[key] =
                  '[]'; // Endpoint bindings are deliberately not portable.
            } else if (key == 'long_task_json') {
              final task = Map<String, dynamic>.from(
                jsonDecode(value as String) as Map,
              );
              if (!{
                'completed',
                'failed',
                'cancelled',
              }.contains(task['status'])) {
                task['status'] = 'cancelled';
                task['error'] = '此任务来自备份，不会自动连接原服务器或恢复执行。';
              }
              task['baseUrl'] = '';
              task['uploadBaseUrl'] = '';
              task['providerProfileId'] = '';
              task['taskId'] = null;
              task['remoteFileIds'] = <String>[];
              row[key] = jsonEncode(task);
            } else if (key == 'active_children_json') {
              final active = jsonDecode(value as String) as Map;
              row[key] = jsonEncode({
                for (final e in active.entries)
                  e.key == ''
                      ? e.key
                      : remap(e.key as String): e.value == kCheckpointEnd
                      ? kCheckpointEnd
                      : remap(e.value as String),
              });
            } else {
              row[key] = jsonEncode(
                _remapJson(
                  jsonDecode(value as String),
                  remap,
                  ids: key.endsWith('_ids_json') || key == 'references_json',
                ),
              );
            }
          }
        }
      }
    }
    final oldMemory = await memory.read() ?? '';
    final current = _codec.decode(oldMemory);
    // Remap only managed identifier metadata, preserving manual Markdown and
    // unknown metadata from both vaults instead of dropping unparsed lines.
    final entryPattern = RegExp(r'^(- \[id:)([^\]]+)(\].*)$');
    final referencePattern = RegExp(
      r'^(  - (?:source_conversation_id|source_message_id|project_id):\s*)(\S+)(\s*)$',
    );
    final importedText = (payload['memory'] as String)
        .split('\n')
        .map((line) {
          final entry = entryPattern.firstMatch(line);
          if (entry != null) {
            return '${entry[1]}${remap(entry[2]!.trim())}${entry[3]}';
          }
          final reference = referencePattern.firstMatch(line);
          if (reference != null) {
            return '${reference[1]}${remap(reference[2]!)}${reference[3]}';
          }
          if (line.startsWith('revision:')) {
            return 'revision: ${current.revision + 1}';
          }
          return line;
        })
        .join('\n');
    // Keep all existing user-edited Markdown verbatim, not just codec-managed
    // bullets. Only its revision advances; imported entries append below it.
    final merged = oldMemory.trim().isEmpty
        ? importedText
        : '${oldMemory.replaceFirst(RegExp(r"^revision:.*$", multiLine: true), 'revision: ${current.revision + 1}')}\n\n$importedText';
    final preferences = restorePreferences
        ? Map<String, dynamic>.from(payload['preferences'] as Map)
        : <String, dynamic>{};
    // Full imports preserve any existing capability/user-library configuration.
    // The dedicated settings importer provides reviewed additive merges.
    for (final key in CapabilitySettingsBundle.keys) {
      if (prefs.containsKey(key)) preferences.remove(key);
    }
    preferences.remove(_learningPlansKey);
    preferences.remove(_workMemoryKey);
    for (final key in TaskDataBackup.keys) {
      preferences.remove(key);
    }
    preferences.addAll(
      TaskDataBackup.restoreValues(
        {for (final key in TaskDataBackup.keys) key: prefs.get(key)},
        Map<String, dynamic>.from(payload['preferences'] as Map),
        remap,
      ),
    );
    final importedMemory = _workMemoryRows(
      payload['preferences'][_workMemoryKey],
    );
    if (importedMemory.isNotEmpty) {
      final currentMemory = _workMemoryRows(prefs.getString(_workMemoryKey));
      preferences[_workMemoryKey] = jsonEncode({
        ...currentMemory,
        for (final entry in importedMemory.entries)
          remap(entry.key): entry.value,
      });
    }

    final importedPlans = _learningPlanRows(
      payload['preferences'][_learningPlansKey],
    );
    if (importedPlans.isNotEmpty) {
      final currentPlans = _learningPlanRows(
        prefs.getString(_learningPlansKey),
      );
      preferences[_learningPlansKey] = jsonEncode([
        ...currentPlans,
        // Knowledge IDs are scoped to each plan; preserve their references.
        for (final plan in importedPlans) {...plan, 'id': _uuid.v4()},
      ]);
    }
    final undo = <String, dynamic>{
      'id': _uuid.v4(),
      'memory': oldMemory,
      'files': stagedPaths,
      'preferences': {for (final key in preferences.keys) key: prefs.get(key)},
    };
    await journal.write(undo);
    try {
      for (final job in fileJobs) {
        await files.writeBytes(
          id: job.id,
          fileName: job.name,
          image: job.image,
          bytes: base64Decode(job.encoded),
        );
      }
      await db.transaction(() async {
        for (final name in tableNames) {
          for (final row in tables[name]!) {
            final columns = row.keys.map((c) => '"$c"').join(',');
            final placeholders = List.filled(row.length, '?').join(',');
            await db.customStatement(
              'INSERT INTO "$name" ($columns) VALUES ($placeholders)',
              row.values.toList(),
            );
          }
        }
        // These writes finish BEFORE SQL commit. A process crash leaves either
        // the marker (keep new data), or the undo journal (restore old data).
        if (importedText.trim().isNotEmpty) await memory.write(merged);
        await _writePreferences(preferences);
        await db
            .into(db.backupImports)
            .insert(
              BackupImportsCompanion.insert(
                id: undo['id'] as String,
                committedAt: DateTime.now(),
              ),
            );
      });
    } catch (_) {
      await recoverPending();
      rethrow;
    }
    // Cleanup failure must not report a committed import as failed (and tempt
    // a duplicate retry). Startup can safely finish this cleanup next time.
    try {
      await recoverPending();
    } catch (_) {}
  });

  Future<void> recoverPending() async {
    final undo = await journal.read();
    if (undo == null) return;
    final committed = await (db.select(
      db.backupImports,
    )..where((r) => r.id.equals(undo['id'] as String))).getSingleOrNull();
    if (committed == null) {
      // Validate every target before any deletion, never accept broad paths.
      final paths = [
        for (final path in undo['files'] as List)
          validateLibraryPath(path as String),
      ];
      await memory.write(undo['memory'] as String);
      final oldPreferences = Map<String, dynamic>.from(
        undo['preferences'] as Map,
      );
      if (!oldPreferences.keys.every(_storedKeys.contains)) {
        throw const FormatException('恢复日志设置字段不合法。');
      }
      await _writePreferences(oldPreferences);
      for (final path in paths) {
        // Never remove an asset that has acquired a live DB reference.
        final referenced = await (db.select(
          db.libraryItems,
        )..where((r) => r.relativePath.equals(path))).getSingleOrNull();
        if (referenced == null) await files.delete(path);
      }
    }
    await journal.clear();
    await (db.delete(
      db.backupImports,
    )..where((r) => r.id.equals(undo['id'] as String))).go();
  }

  Future<void> _writePreferences(Map<String, dynamic> values) async {
    for (final e in values.entries) {
      final value = e.value;
      final ok = switch (value) {
        null => await prefs.remove(e.key),
        String() => await prefs.setString(e.key, value),
        bool() => await prefs.setBool(e.key, value),
        int() => await prefs.setInt(e.key, value),
        double() => await prefs.setDouble(e.key, value),
        _ => throw const FormatException('偏好设置类型错误。'),
      };
      if (!ok) throw StateError('偏好设置写入失败：${e.key}');
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_busy) throw StateError('备份或恢复正在进行。');
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  static void _checkRecordCount(int count) {
    if (count > maxRecords) {
      throw const FormatException('备份记录数超过 $maxRecords 条。');
    }
  }
}

dynamic _remapJson(
  dynamic value,
  String Function(String) remap, {
  bool ids = false,
}) {
  if (value is List) {
    return [for (final v in value) _remapJson(v, remap, ids: ids)];
  }
  if (value is Map) {
    return {
      for (final e in value.entries)
        e.key: _remapJson(
          e.value,
          remap,
          ids:
              e.key == 'id' ||
              (e.key as String).endsWith('Id') ||
              (e.key as String).endsWith('Ids'),
        ),
    };
  }
  return ids && value is String && value.isNotEmpty ? remap(value) : value;
}

class BackupPreview {
  BackupPreview._(this._payload, this.sourceSchemaVersion);
  final Map<String, dynamic> _payload;
  final int sourceSchemaVersion;
  int get targetSchemaVersion => _payload['schemaVersion'] as int;
  bool get requiresUpgrade => sourceSchemaVersion != targetSchemaVersion;
  int count(String table) => (_payload['tables'][table] as List).length;
  int get learningPlans => FullBackupService._learningPlanRows(
    _payload['preferences'][FullBackupService._learningPlansKey],
  ).length;
  int get memories => const MemoryMarkdownCodec()
      .decode(_payload['memory'] as String)
      .entries
      .length;
  String get createdAt => _payload['createdAt'] as String? ?? '';
}
