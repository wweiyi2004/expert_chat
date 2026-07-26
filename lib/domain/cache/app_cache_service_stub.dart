import 'cache_clear_result.dart';

/// Browser builds have no app-owned native temporary directory. Memory caches
/// are cleared by the caller.
class AppCacheService {
  AppCacheService({Object? directoryProvider});

  Future<CacheClearResult> clearOwnedTemporaryFiles() async =>
      const CacheClearResult();
}
