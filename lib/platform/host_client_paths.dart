import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Keep GUI platform-plugin storage inside an explicitly selected host profile.
/// The default installed profile continues using the platform's normal paths.
void installHostProfilePaths(String? directory) {
  if (directory == null) return;
  if (!p.isAbsolute(directory)) {
    throw ArgumentError('Host data directory must be absolute');
  }
  PathProviderPlatform.instance = _HostProfilePaths(
    PathProviderPlatform.instance,
    p.normalize(directory),
  );
}

class _HostProfilePaths extends PathProviderPlatform {
  _HostProfilePaths(this.delegate, this.root);
  final PathProviderPlatform delegate;
  final String root;
  Future<String> _directory(String name) async =>
      (await Directory(p.join(root, name)).create(recursive: true)).path;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() => _directory('documents');
  @override
  Future<String?> getApplicationCachePath() => _directory('cache');
  @override
  Future<String?> getTemporaryPath() => _directory('tmp');
  @override
  Future<String?> getLibraryPath() => _directory('library');
  @override
  Future<String?> getDownloadsPath() => delegate.getDownloadsPath();
  @override
  Future<String?> getExternalStoragePath() => delegate.getExternalStoragePath();
  @override
  Future<List<String>?> getExternalCachePaths() =>
      delegate.getExternalCachePaths();
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      delegate.getExternalStoragePaths(type: type);
}
