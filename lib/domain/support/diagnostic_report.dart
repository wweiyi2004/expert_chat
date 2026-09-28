import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../data/backup_codec.dart';
import '../../data/backup_migrations.dart';
import '../../data/db/app_database.dart';
import '../errors/app_failure.dart';

class DiagnosticInfo {
  const DiagnosticInfo({
    required this.version,
    required this.build,
    required this.platform,
  });
  final String version;
  final String build;
  final String platform;

  static Future<DiagnosticInfo> load() async {
    final platform = kIsWeb ? 'Web' : defaultTargetPlatform.name;
    try {
      final info = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 3),
      );
      return DiagnosticInfo(
        version: info.version,
        build: info.buildNumber,
        platform: platform,
      );
    } catch (_) {
      return DiagnosticInfo(version: '无法读取', build: '未知', platform: platform);
    }
  }
}

/// All fields are explicit metadata. No settings, credentials, message text,
/// filenames, endpoints or arbitrary exception strings enter the report.
class DiagnosticReport {
  DiagnosticReport({
    required this.info,
    this.failure,
    this.countsRequested = false,
    this.counts,
    this.countsFailure,
  });
  final DiagnosticInfo info;
  final FailureKind? failure;
  final bool countsRequested;
  final Map<String, int>? counts;
  final FailureKind? countsFailure;

  static const countLabels = {
    'conversations': '会话数量',
    'messages': '消息数量',
    'library_items': '素材数量',
    'projects': '项目数量',
    'generation_records': '生图记录数量',
  };

  String toText() {
    String singleLine(String value) =>
        value.replaceAll(RegExp(r'[\r\n]'), ' ').trim();
    final text = StringBuffer('Expert Chat 问题报告\n\n')
      ..writeln('应用版本：${singleLine(info.version)}+${singleLine(info.build)}')
      ..writeln('平台：${singleLine(info.platform)}')
      ..writeln('应用数据版本：${BackupMigrations.currentSchema}')
      ..writeln('备份格式版本：${BackupCodec.version}')
      ..writeln('错误类别：${failure?.name ?? '未提供'}');
    if (countsRequested) {
      text.writeln('\n本地数据数量（用户选择包含）：');
      if (counts == null) {
        text.writeln('暂时无法读取：${countsFailure?.name ?? 'unknown'}');
      } else {
        for (final entry in countLabels.entries) {
          final count = counts![entry.key];
          if (count != null && count >= 0) {
            text.writeln('${entry.value}：$count');
          }
        }
      }
    }
    text.writeln('\n问题描述：\n\n复现步骤：\n1. \n2. \n\n期望结果：\n\n实际结果：');
    return text.toString();
  }
}

/// Aggregate-only queries: no archive bodies or local file paths are read.
Future<Map<String, int>> readDiagnosticCounts(AppDatabase database) async {
  final result = <String, int>{};
  for (final table in DiagnosticReport.countLabels.keys) {
    final row = await database
        .customSelect('SELECT COUNT(*) AS total FROM "$table"')
        .getSingle();
    result[table] = row.read<int>('total');
  }
  return result;
}
