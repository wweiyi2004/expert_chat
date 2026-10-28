import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../data/settings_state.dart';
import '../data/settings_storage_keys.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/tools/search_provider.dart';

/// Search credentials are independent of whichever model/provider is answering.
Future<SettingsState> resolveDeepSeekSearchSettings(
  Ref ref,
  SettingsState settings,
) => resolveDeepSeekSearchCredentials(
  settings,
  (key) => ref.read(secureStorageProvider).read(key: key),
);

Future<SettingsState> resolveDeepSeekSearchCredentials(
  SettingsState settings,
  Future<String?> Function(String key) readKey,
) async {
  var key = settings.effectiveSearchApiKey.trim();
  if (key.isEmpty) {
    for (final profile in settings.profiles.where(
      (p) => ModelCatalog.isOfficialDeepSeekEndpoint(p.baseUrl),
    )) {
      final saved = await readKey(providerApiKeyStorageKey(profile.id));
      if (saved?.trim().isNotEmpty == true) {
        key = saved!.trim();
        break;
      }
    }
  }
  return settings.copyWith(
    searchBackend: SearchBackend.deepseek,
    searchApiKey: key,
  );
}
