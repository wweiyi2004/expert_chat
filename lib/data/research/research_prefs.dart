import 'package:shared_preferences/shared_preferences.dart';

import 'ssh_profile.dart';

/// Non-secret research-mode preferences (profiles list, AI context lines).
class ResearchPrefs {
  ResearchPrefs(this._prefs);

  final SharedPreferences _prefs;

  static const profilesKey = 'researchSshProfiles';
  static const aiContextLinesKey = 'researchAiContextLines';
  static const blockCtrlCKey = 'researchBlockCtrlC';
  static const defaultAiContextLines = 36;

  /// Default on: observing long training jobs must not die to accidental Ctrl+C.
  static const defaultBlockCtrlC = true;

  List<SshProfile> loadProfiles() =>
      SshProfile.listFromJson(_prefs.getString(profilesKey));

  Future<void> saveProfiles(List<SshProfile> profiles) =>
      _prefs.setString(profilesKey, SshProfile.listToJson(profiles));

  int loadAiContextLines() {
    final v = _prefs.getInt(aiContextLinesKey) ?? defaultAiContextLines;
    if (v == 20 || v == 36 || v == 50 || v == 100) return v;
    return defaultAiContextLines;
  }

  Future<void> saveAiContextLines(int lines) =>
      _prefs.setInt(aiContextLinesKey, lines);

  bool loadBlockCtrlC() =>
      _prefs.getBool(blockCtrlCKey) ?? defaultBlockCtrlC;

  Future<void> saveBlockCtrlC(bool value) =>
      _prefs.setBool(blockCtrlCKey, value);
}

/// Secure-storage key helpers for SSH secrets (never log these values).
abstract final class ResearchSecureKeys {
  static String password(String profileId) => 'research_ssh_pw_$profileId';
  static String privateKey(String profileId) => 'research_ssh_key_$profileId';
  static String passphrase(String profileId) => 'research_ssh_ph_$profileId';
}
