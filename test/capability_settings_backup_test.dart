import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/capability_settings_bundle.dart';
import 'package:expert_chat/data/settings_bundle.dart';
import 'package:expert_chat/data/subagent_role.dart';
import 'package:expert_chat/state/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'capability configuration roundtrips allowlist and preserves local candidates/groups',
    () async {
      final candidate = {
        'role': const SubagentRole(
          id: 'candidate',
          name: 'Writer',
          when: 'write',
          instructions: 'write carefully',
          enabled: false,
          source: 'fixture',
          version: 2,
        ).toJson(),
        'version': 2,
        'source': 'fixture',
        'requiredTools': [],
        'evidence': [],
        'history': [],
        'disabled': false,
      };
      final values = {
        'modelServicePriorities': {
          'model': ['a', 'b'],
        },
        'modelRouteGroups.v1': {
          'groups': [
            {
              'id': 'group',
              'name': 'Group',
              'models': ['model'],
              'failover': true,
            },
          ],
          'autoGroup': 'group',
        },
        'trustedToolRegistry.v1': {
          'mathEnabled': true,
          'pythonExecutable': 'python',
        },
        'taskSupervisor.v1': {
          'enabled': false,
          'model': 'model',
          'prompt': 'custom review',
          'maxReviews': 3,
          'minRoundGap': 2,
        },
        'roleValidation.v1': {
          'enabled': false,
          'autoPromote': false,
          'model': '__current__',
          'prompt': 'custom validation',
          'maxReviewsPerTask': 2,
        },
        'roleEvolution.v1': [candidate],
      };
      SharedPreferences.setMockInitialValues({
        for (final entry in values.entries) entry.key: jsonEncode(entry.value),
        'magpieCompanion.v1': '{"private":"not-exported"}',
        'workRuntimeLogs.v1': 'private-log',
        'model_oauth_fixture': 'not-exported',
      });
      final prefs = await SharedPreferences.getInstance();
      final exported = CapabilitySettingsBundle.read(prefs);
      expect(
        (exported['values'] as Map).keys.toSet(),
        CapabilitySettingsBundle.keys,
      );
      expect(jsonEncode(exported), isNot(contains('not-exported')));
      final normalized = CapabilitySettingsBundle.validate(exported);
      await prefs.clear();
      await CapabilitySettingsBundle.apply(prefs, normalized);
      expect(CapabilitySettingsBundle.read(prefs), exported);
      final changed = {...candidate, 'source': 'user edit'};
      await prefs.setString('roleEvolution.v1', jsonEncode([changed]));
      await CapabilitySettingsBundle.apply(prefs, normalized);
      expect(
        (jsonDecode(prefs.getString('roleEvolution.v1')!) as List)
            .single['source'],
        'user edit',
      );
    },
  );
  test(
    'atomic automatic append preserves user role writes and disabled pending review cannot append',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsControllerProvider.future);
      final settings = container.read(settingsControllerProvider.notifier);
      const custom = SubagentRole(
        id: 'custom',
        name: 'User',
        when: 'user scope',
        instructions: 'user override',
        source: 'user',
      );
      const generated = SubagentRole(
        id: 'generated',
        name: 'Generated',
        when: 'scope',
        instructions: 'verified',
        source: 'model',
      );
      final userWrite = settings.setSubagentRoles([custom]);
      final append = settings.appendValidatedRoleIfAbsent(generated);
      await userWrite;
      expect(await append, true);
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .effectiveSubagentRoles
            .map((r) => r.id),
        ['custom', 'generated'],
      );
      expect(
        await settings.appendValidatedRoleIfAbsent(
          custom.copyWith(instructions: 'overwrite'),
        ),
        false,
      );
      var optIn = true;
      final earlier = settings.setSubagentRoles([custom]);
      final pending = settings.appendValidatedRoleIfAbsent(
        generated,
        stillValid: () => optIn,
      );
      optIn = false;
      await earlier;
      expect(await pending, false);
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .effectiveSubagentRoles
            .single
            .instructions,
        'user override',
      );
      await settings.importSettingsJson(
        SettingsBundle.encode({
          'subagentRoles': [
            custom.copyWith(instructions: 'imported overwrite').toJson(),
          ],
          'capabilitySettings': {'version': 1, 'values': {}},
        }),
      );
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .effectiveSubagentRoles
            .single
            .instructions,
        'user override',
      );
    },
  );
}
