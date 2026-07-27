import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'install_apk.dart';

/// GitHub repo used for release notes and binary downloads.
const kGithubOwner = 'wweiyi2004';
const kGithubRepo = 'expert_chat';
const kGithubReleasesApi =
    'https://api.github.com/repos/$kGithubOwner/$kGithubRepo/releases/latest';
const kGithubReleasesPage =
    'https://github.com/$kGithubOwner/$kGithubRepo/releases';

/// Result of comparing the running app to the latest GitHub Release.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    required this.releaseUrl,
    required this.releaseNotes,
    this.downloadUrl,
    this.assetName,
    this.tagName,
    this.assetSha256,
  });

  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final String releaseUrl;
  final String releaseNotes;
  final String? downloadUrl;

  /// Matched release asset file name (for local save / install).
  final String? assetName;
  final String? tagName;

  /// Optional GitHub asset digest (`sha256:…` stripped to bare hex).
  final String? assetSha256;

  bool get isAndroidApk {
    final n = (assetName ?? downloadUrl ?? '').toLowerCase();
    return n.endsWith('.apk');
  }

  bool get isWindowsZip {
    final n = (assetName ?? downloadUrl ?? '').toLowerCase();
    return n.endsWith('.zip') || n.endsWith('.msix') || n.endsWith('.exe');
  }
}

/// Checks GitHub Releases for a newer version and resolves a platform asset.
class AppUpdateChecker {
  AppUpdateChecker({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<UpdateCheckResult> check({String? preferredAbi}) async {
    final info = await PackageInfo.fromPlatform();
    final current = normalizeVersion(info.version);

    final response = await _dio.get<Map<String, dynamic>>(
      kGithubReleasesApi,
      options: Options(
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'expert_chat-update-check',
        },
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (s) => s != null && s < 500,
      ),
    );

    if (response.statusCode == 404) {
      return UpdateCheckResult(
        currentVersion: current,
        latestVersion: current,
        hasUpdate: false,
        releaseUrl: kGithubReleasesPage,
        releaseNotes: '',
      );
    }
    if (response.statusCode != 200 || response.data == null) {
      throw Exception('检查更新失败（HTTP ${response.statusCode}）');
    }

    final data = response.data!;
    final tag = (data['tag_name'] as String? ?? '').trim();
    final latest = normalizeVersion(tag);
    final htmlUrl = (data['html_url'] as String?)?.trim().isNotEmpty == true
        ? data['html_url'] as String
        : kGithubReleasesPage;
    var notes = (data['body'] as String? ?? '').trim();
    if (notes.startsWith('\uFEFF')) notes = notes.substring(1).trim();
    final assets = (data['assets'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    final abi = preferredAbi ?? await InstallApk.primaryAbi();
    final picked = pickAsset(assets, abiHint: abi);

    final hasUpdate = isNewer(latest, current);
    return UpdateCheckResult(
      currentVersion: current,
      latestVersion: latest.isEmpty ? current : latest,
      hasUpdate: hasUpdate,
      releaseUrl: htmlUrl,
      releaseNotes: notes,
      downloadUrl: picked?.url,
      assetName: picked?.name,
      tagName: tag.isEmpty ? null : tag,
      assetSha256: picked?.sha256,
    );
  }

  /// Strip a leading `v` and `+build` metadata. Pre-release identifiers are
  /// kept so `1.2.0-beta` can order below `1.2.0` in [isNewer].
  static String normalizeVersion(String raw) {
    var v = raw.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    final plus = v.indexOf('+');
    if (plus >= 0) v = v.substring(0, plus);
    return v.trim();
  }

  static bool isNewer(String latest, String current) {
    final a = _parse(latest);
    final b = _parse(current);
    if (a == null || b == null) return latest != current && latest.isNotEmpty;
    for (var i = 0; i < 3; i++) {
      if (a.nums[i] != b.nums[i]) return a.nums[i] > b.nums[i];
    }
    return _comparePreRelease(a.pre, b.pre) > 0;
  }

  // Test aliases (same as public API).
  static String normalizeVersionForTest(String raw) => normalizeVersion(raw);
  static bool isNewerForTest(String latest, String current) =>
      isNewer(latest, current);

  static ({List<int> nums, String pre})? _parse(String v) {
    final dash = v.indexOf('-');
    final core = dash >= 0 ? v.substring(0, dash) : v;
    final pre = dash >= 0 ? v.substring(dash + 1) : '';
    final parts = core.split('.');
    if (parts.isEmpty) return null;
    final out = <int>[0, 0, 0];
    for (var i = 0; i < 3; i++) {
      if (i < parts.length) {
        out[i] = int.tryParse(parts[i]) ?? 0;
      }
    }
    return (nums: out, pre: pre);
  }

  /// SemVer ordering for pre-release suffixes of the same core version: a
  /// release outranks any pre-release, and two pre-releases compare identifier
  /// by identifier (numeric identifiers numerically, others lexically).
  static int _comparePreRelease(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 0;
    if (a.isEmpty) return 1;
    if (b.isEmpty) return -1;
    final aParts = a.split('.');
    final bParts = b.split('.');
    for (var i = 0; i < aParts.length && i < bParts.length; i++) {
      final an = int.tryParse(aParts[i]);
      final bn = int.tryParse(bParts[i]);
      final int cmp;
      if (an != null && bn != null) {
        cmp = an.compareTo(bn);
      } else if (an != null) {
        cmp = -1; // numeric identifiers sort below alphanumeric ones
      } else if (bn != null) {
        cmp = 1;
      } else {
        cmp = aParts[i].compareTo(bParts[i]);
      }
      if (cmp != 0) return cmp;
    }
    return aParts.length.compareTo(bParts.length);
  }

  /// Strip `sha256:` prefix from a GitHub release asset `digest` field.
  static String? normalizeAssetSha256(String? raw) {
    if (raw == null) return null;
    var d = raw.trim().toLowerCase();
    if (d.startsWith('sha256:')) d = d.substring(7).trim();
    if (d.isEmpty) return null;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(d)) return null;
    return d;
  }

  /// Public for tests. Picks the best installable asset for this platform.
  ///
  /// [platform] overrides the host platform (useful in unit tests).
  static ({String name, String url, String? sha256})? pickAsset(
    List<Map<String, dynamic>> assets, {
    String? abiHint,
    TargetPlatform? platform,
  }) {
    if (assets.isEmpty) return null;

    final plat = platform ??
        (kIsWeb
            ? TargetPlatform.android
            : defaultTargetPlatform);

    ({String name, String url, String? sha256})? at(int i) {
      final name = (assets[i]['name'] as String? ?? '').trim();
      final url = (assets[i]['browser_download_url'] as String? ?? '').trim();
      if (name.isEmpty || url.isEmpty) return null;
      return (
        name: name,
        url: url,
        sha256: normalizeAssetSha256(assets[i]['digest'] as String?),
      );
    }

    bool match(int i, bool Function(String n) test) {
      final name = (assets[i]['name'] as String? ?? '').toLowerCase();
      return name.isNotEmpty && test(name);
    }

    ({String name, String url, String? sha256})? firstWhere(
      bool Function(String n) test,
    ) {
      for (var i = 0; i < assets.length; i++) {
        if (match(i, test)) return at(i);
      }
      return null;
    }

    // Prefer platform-specific installers from our release naming scheme.
    if (!kIsWeb && plat == TargetPlatform.android) {
      final abi = (abiHint ?? '').toLowerCase();
      // Split APKs: arm64-v8a → arm64, armeabi-v7a → armeabi / v7a, x86_64.
      if (abi.contains('arm64')) {
        final hit = firstWhere(
          (n) => n.endsWith('.apk') && n.contains('arm64'),
        );
        if (hit != null) return hit;
      } else if (abi.contains('armeabi') || abi.contains('armv7')) {
        final hit = firstWhere(
          (n) =>
              n.endsWith('.apk') &&
              (n.contains('armeabi') || n.contains('v7a')) &&
              !n.contains('arm64'),
        );
        if (hit != null) return hit;
      } else if (abi.contains('x86_64') || abi == 'x64') {
        final hit = firstWhere(
          (n) =>
              n.endsWith('.apk') &&
              (n.contains('x86_64') || n.contains('x64')),
        );
        if (hit != null) return hit;
      }

      // After an ABI-specific miss, only accept universal. Falling back to
      // "any android apk" / "any apk" would hand an arm64-only release to a
      // v7a device (install fail or UnsatisfiedLinkError).
      return firstWhere((n) => n.endsWith('.apk') && n.contains('universal'));
    }
    if (!kIsWeb && plat == TargetPlatform.windows) {
      return firstWhere(
            (n) =>
                (n.endsWith('.zip') ||
                    n.endsWith('.msix') ||
                    n.endsWith('.exe')) &&
                n.contains('windows'),
          ) ??
          firstWhere((n) => n.endsWith('.zip') && n.contains('win'));
    }
    if (!kIsWeb && plat == TargetPlatform.macOS) {
      return firstWhere(
        (n) => n.contains('mac') && (n.endsWith('.dmg') || n.endsWith('.zip')),
      );
    }

    for (final a in assets) {
      final name = (a['name'] as String? ?? '').trim();
      final u = (a['browser_download_url'] as String? ?? '').trim();
      if (u.isNotEmpty) {
        return (
          name: name.isEmpty ? 'download' : name,
          url: u,
          sha256: null,
        );
      }
    }
    return null;
  }
}
