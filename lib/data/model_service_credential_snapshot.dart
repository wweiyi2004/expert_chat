import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'provider_profile.dart';

String providerCredentialBindingStorageKey(String id) =>
    'provider_credential_binding_$id';
String modelCredentialBinding(ProviderProfile profile, String key) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'baseUrl': profile.baseUrl.replaceFirst(RegExp(r'/+$'), ''),
          'authMode': profile.authMode,
          'key': key,
        }),
      ),
    )
    .toString();

/// A coherent read, never serialized or interpolated into diagnostics.
class ModelServiceCredentialSnapshot {
  const ModelServiceCredentialSnapshot({
    required this.profile,
    required this.apiKey,
    required this.epoch,
  });
  final ProviderProfile profile;
  final String apiKey;
  final int epoch;
}
