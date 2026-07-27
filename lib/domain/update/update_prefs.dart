import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which full-package release the user chose to skip.
class UpdatePrefs {
  UpdatePrefs(this._prefs);

  final SharedPreferences _prefs;

  static const _kSkipped = 'update_skipped_version';

  String? get skippedVersion {
    final v = _prefs.getString(_kSkipped)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> skipVersion(String version) async {
    final v = version.trim();
    if (v.isEmpty) return;
    await _prefs.setString(_kSkipped, v);
  }

  Future<void> clearSkipped() async {
    await _prefs.remove(_kSkipped);
  }

  bool shouldPrompt(String latestVersion) {
    final skipped = skippedVersion;
    if (skipped == null) return true;
    return skipped != latestVersion.trim();
  }
}
