import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'repository_context.dart';

/// Bounded repository-only discovery. Canonical paths prevent symlink escapes.
class RepositoryContextLoader {
  const RepositoryContextLoader({
    this.maxFileBytes = 32768,
    this.maxTotalBytes = 131072,
    this.maxSkills = 64,
  });
  final int maxFileBytes, maxTotalBytes, maxSkills;
  Future<RepositoryContext> load({
    required String root,
    required String cwd,
    Set<String> namedSkills = const {},
    Set<String> relevantSkillNames = const {},
    bool Function(String path)? canRead,
    List<String> scopedPaths = const [],
  }) async {
    final base = await Directory(root).resolveSymbolicLinks();
    final work = await Directory(cwd).resolveSymbolicLinks();
    if (!_inside(base, work)) {
      throw ArgumentError(
        'Working directory must remain within repository root',
      );
    }
    final warnings = <String>[],
        sources = <RepositorySource>[],
        skills = <RepositorySkill>[];
    var total = 0;
    Future<String?> read(String path) async {
      try {
        if (canRead != null && !canRead(path)) {
          warnings.add('Repository scope denied: $path');
          return null;
        }
        final f = File(path);
        if (!await f.exists()) return null;
        final resolved = await f.resolveSymbolicLinks();
        if (!_inside(base, resolved) ||
            (canRead != null && !canRead(resolved))) {
          warnings.add('Skipped outside repository: $path');
          return null;
        }
        final size = await f.length();
        if (size > maxFileBytes || total + size > maxTotalBytes) {
          warnings.add('Context size limit: $path');
          return null;
        }
        final bytes = await f
            .openRead(0, maxFileBytes + 1)
            .fold<List<int>>([], (a, b) => a..addAll(b));
        if (bytes.length > maxFileBytes ||
            total + bytes.length > maxTotalBytes) {
          return null;
        }
        total += bytes.length;
        return utf8.decode(bytes);
      } on FileSystemException catch (_) {
        warnings.add('Unreadable context: $path');
        return null;
      } on FormatException catch (_) {
        warnings.add('Invalid UTF-8: $path');
        return null;
      }
    }

    final dirs = <String>[base];
    var cursor = base;
    for (final part in p.split(p.relative(work, from: base))) {
      if (part == '.') continue;
      cursor = p.join(cursor, part);
      dirs.add(cursor);
    }
    // Include only ancestors of files this child owns. Sibling instructions remain scoped.
    for (final owned in scopedPaths.take(32)) {
      var candidate = p.normalize(
        p.isAbsolute(owned) ? owned : p.join(base, owned),
      );
      if (!_inside(base, candidate) ||
          (canRead != null && !canRead(candidate))) {
        warnings.add('Skipped owned path outside readable repository: $owned');
        continue;
      }
      if (!await Directory(candidate).exists()) {
        candidate = p.dirname(candidate);
      }
      while (!await Directory(candidate).exists() &&
          _inside(base, candidate) &&
          !p.equals(base, candidate)) {
        candidate = p.dirname(candidate);
      }
      final resolved = await Directory(candidate).resolveSymbolicLinks();
      if (!_inside(base, resolved) || (canRead != null && !canRead(resolved))) {
        continue;
      }
      var ancestor = base;
      for (final part in p.split(p.relative(resolved, from: base))) {
        if (part == '.') {
          continue;
        }
        ancestor = p.join(ancestor, part);
        if (!dirs.any((d) => p.equals(d, ancestor))) {
          dirs.add(ancestor);
        }
      }
    }
    dirs.sort((a, b) {
      final depth = p.split(a).length.compareTo(p.split(b).length);
      return depth != 0 ? depth : a.compareTo(b);
    });
    for (final dir in dirs) {
      for (final name in ['AGENT.md', 'AGENTS.md', 'CLAUDE.md']) {
        final path = p.join(dir, name), content = await read(p.join(dir, name));
        if (content != null) {
          sources.add(
            RepositorySource(
              path: path,
              scope: dir,
              kind: 'rule',
              content: content,
            ),
          );
        }
      }
    }
    for (final dir in dirs) {
      for (final catalog in ['.agents', '.claude']) {
        final skillDir = Directory(p.join(dir, catalog, 'skills'));
        if (canRead != null && !canRead(skillDir.path)) {
          continue;
        }
        if (!await skillDir.exists()) continue;
        final resolved = await skillDir.resolveSymbolicLinks();
        if (!_inside(base, resolved) ||
            (canRead != null && !canRead(resolved))) {
          warnings.add('Skipped outside repository: ${skillDir.path}');
          continue;
        }
        final entries = <FileSystemEntity>[];
        await for (final entry in skillDir.list(followLinks: false)) {
          if (entries.length >= maxSkills) {
            warnings.add('Skill discovery limit: ${skillDir.path}');
            entries.clear();
            break;
          }
          entries.add(entry);
        }
        entries.sort((a, b) => a.path.compareTo(b.path));
        for (final entry in entries) {
          if (entry is! Directory || skills.length >= maxSkills) continue;
          final path = p.join(entry.path, 'SKILL.md');
          // Read bounded metadata only; do not inject every full skill body.
          final content = await read(path);
          if (content == null) continue;
          final frontmatter =
              content.startsWith('---\n') || content.startsWith('---\r\n')
              ? content
                        .split(RegExp(r'^---\s*$', multiLine: true))
                        .skip(1)
                        .firstOrNull ??
                    ''
              : '';
          final nameMatch = RegExp(
            r'^name:\s*(.+)$',
            multiLine: true,
          ).firstMatch(frontmatter);
          final descMatch = RegExp(
            r'^description:\s*(.+)$',
            multiLine: true,
          ).firstMatch(frontmatter);
          final name =
              nameMatch
                  ?.group(1)
                  ?.trim()
                  .replaceAll(RegExp(r'''^["']|["']$'''), '') ??
              p.basename(entry.path);
          skills.add(
            RepositorySkill(
              name: name,
              description: descMatch?.group(1)?.trim() ?? '',
              path: path,
              scope: dir,
            ),
          );
          if (namedSkills.contains(name) || relevantSkillNames.contains(name)) {
            sources.add(
              RepositorySource(
                path: path,
                scope: dir,
                kind: 'skill',
                content: content,
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

  bool _inside(String root, String path) =>
      p.equals(root, path) || p.isWithin(root, path);
}
