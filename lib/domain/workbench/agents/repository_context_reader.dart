import 'dart:convert';
import 'package:path/path.dart' as p;
import 'repository_context.dart';

class RepositoryEntry {
  const RepositoryEntry(this.name, {this.directory = false, this.bytes});
  final String name;
  final bool directory;
  final int? bytes;
}

/// Uses host-authorized reads for local and remote workspaces. Never runs code.
class RepositoryContextReaderLoader {
  const RepositoryContextReaderLoader({
    this.maxFileBytes = 32768,
    this.maxTotalBytes = 131072,
    this.maxSkills = 64,
    this.maxCalls = 192,
  });
  final int maxFileBytes, maxTotalBytes, maxSkills, maxCalls;
  Future<RepositoryContext> load({
    required String rootLabel,
    String cwd = '.',
    List<String> scopedPaths = const [],
    Set<String> namedSkills = const {},
    required Future<String?> Function(String) readFile,
    required Future<List<RepositoryEntry>?> Function(String) listDirectory,
  }) async {
    final sources = <RepositorySource>[],
        skills = <RepositorySkill>[],
        warnings = <String>[];
    final cache = <String, List<RepositoryEntry>?>{};
    var calls = 0, total = 0;
    String? safe(String path) {
      final normalized = p.posix.normalize(path.replaceAll('\\', '/'));
      if (p.posix.isAbsolute(normalized) ||
          RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
          normalized == '..' ||
          normalized.startsWith('../')) {
        return null;
      }
      return normalized;
    }

    String label(String path) {
      final normalized = p.posix.normalize(path);
      return normalized == '.' ? rootLabel : '$rootLabel/$normalized';
    }

    Future<List<RepositoryEntry>?> entries(String dir) async {
      dir = p.posix.normalize(dir);
      if (cache.containsKey(dir)) {
        return cache[dir];
      }
      if (calls++ >= maxCalls) {
        warnings.add('仓库规则读取调用达到上限');
        return null;
      }
      try {
        final values = await listDirectory(dir);
        if (values == null) {
          cache[dir] = null;
          return null;
        }
        if (values.length > 10000) {
          warnings.add('目录条目超过上限：${label(dir)}');
          cache[dir] = null;
          return null;
        }
        final valid =
            values
                .where(
                  (e) =>
                      e.name.isNotEmpty &&
                      e.name != '.' &&
                      e.name != '..' &&
                      !e.name.contains('/') &&
                      !e.name.contains('\\'),
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name));
        cache[dir] = valid;
        return valid;
      } catch (error) {
        warnings.add('宿主未允许读取目录 ${label(dir)}：$error');
        cache[dir] = null;
        return null;
      }
    }

    Future<String?> read(String path) async {
      path = p.posix.normalize(path);
      final listing = await entries(p.posix.dirname(path));
      final entry = listing
          ?.where((e) => e.name == p.posix.basename(path) && !e.directory)
          .firstOrNull;
      if (entry == null) {
        return null;
      }
      if ((entry.bytes ?? 0) > maxFileBytes) {
        warnings.add('仓库文件超过读取上限：${label(path)}');
        return null;
      }
      if (calls++ >= maxCalls) {
        warnings.add('仓库规则读取调用达到上限');
        return null;
      }
      try {
        final text = await readFile(path);
        if (text == null) {
          return null;
        }
        final bytes = utf8.encode(text).length;
        if (bytes > maxFileBytes || total + bytes > maxTotalBytes) {
          warnings.add('仓库上下文超过大小上限：${label(path)}');
          return null;
        }
        total += bytes;
        return text;
      } catch (error) {
        warnings.add('宿主未允许读取文件 ${label(path)}：$error');
        return null;
      }
    }

    final dirs = <String>{'.'};
    void addAncestors(String relative) {
      var current = '.';
      for (final part in p.posix.split(relative)) {
        if (part == '.') {
          continue;
        }
        current = p.posix.join(current, part);
        dirs.add(current);
      }
    }

    final work = safe(cwd);
    if (work == null) {
      throw ArgumentError('Working directory outside repository');
    }
    addAncestors(work);
    for (final path in scopedPaths.take(32)) {
      final relative = safe(path);
      if (relative == null) {
        warnings.add('职责路径不在仓库中：$path');
        continue;
      }
      final parent = p.posix.dirname(relative),
          name = p.posix.basename(relative);
      final parentEntries = await entries(parent);
      final isDirectory =
          parentEntries?.any((e) => e.name == name && e.directory) == true;
      addAncestors(isDirectory ? relative : parent);
    }
    final ordered = dirs.toList()
      ..sort((a, b) {
        final depth = p.posix
            .split(a)
            .length
            .compareTo(p.posix.split(b).length);
        return depth == 0 ? a.compareTo(b) : depth;
      });
    for (final dir in ordered) {
      for (final name in ['AGENT.md', 'AGENTS.md', 'CLAUDE.md']) {
        final path = p.posix.join(dir, name),
            text = await read(p.posix.join(dir, name));
        if (text != null) {
          sources.add(
            RepositorySource(
              path: label(path),
              scope: label(dir),
              kind: 'rule',
              content: text,
            ),
          );
        }
      }
    }
    for (final dir in ordered) {
      for (final catalog in ['.agents', '.claude']) {
        final path = p.posix.join(dir, catalog, 'skills');
        // Only probe directories advertised by the authorized parent listing.
        final parents = await entries(dir);
        if (parents?.any((e) => e.name == catalog && e.directory) != true) {
          continue;
        }
        final catalogEntries = await entries(p.posix.join(dir, catalog));
        if (catalogEntries?.any((e) => e.name == 'skills' && e.directory) !=
            true) {
          continue;
        }
        final children = await entries(path);
        if (children == null) {
          continue;
        }
        final folders = children.where((e) => e.directory).toList();
        if (folders.length > maxSkills) {
          warnings.add('技能目录超过发现上限：${label(path)}');
          continue;
        }
        for (final folder in folders) {
          if (skills.length >= maxSkills) {
            warnings.add('技能数量达到上限');
            break;
          }
          final skillPath = p.posix.join(path, folder.name, 'SKILL.md'),
              text = await read(p.posix.join(path, folder.name, 'SKILL.md'));
          if (text == null) {
            continue;
          }
          final header =
              (text.startsWith('---\n') || text.startsWith('---\r\n'))
              ? text
                        .split(RegExp(r'^---\s*$', multiLine: true))
                        .skip(1)
                        .firstOrNull ??
                    ''
              : '';
          String? field(String key) =>
              RegExp('^$key:\\s*(.+)\$', multiLine: true)
                  .firstMatch(header)
                  ?.group(1)
                  ?.trim()
                  .replaceAll(RegExp(r'''^["']|["']$'''), '');
          final name = field('name') ?? folder.name;
          skills.add(
            RepositorySkill(
              name: name,
              description: field('description') ?? '',
              path: label(skillPath),
              scope: label(dir),
            ),
          );
          if (namedSkills.contains(name)) {
            sources.add(
              RepositorySource(
                path: label(skillPath),
                scope: label(dir),
                kind: 'skill',
                content: text,
              ),
            );
          }
        }
      }
    }
    return RepositoryContext(
      sources: sources,
      skills: skills,
      warnings: warnings,
    );
  }
}
