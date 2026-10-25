import 'repository_context.dart';

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
  }) async => RepositoryContext(
    sources: [],
    skills: [],
    warnings: ['Repository context unavailable on this platform'],
  );
}
