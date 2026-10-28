import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/features/tui_bridge/backend.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/model_service_credentials.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _Credentials extends FakeSettings {
  String inactiveKey = 'inactive-secret-first';
  int reads = 0;
  Completer<void>? entered, gate;
  @override
  Future<SettingsState> build() async {
    final settings = await super.build();
    return settings.copyWith(
      profiles: [
        ...settings.profiles,
        ProviderProfile(
          id: 'inactive',
          name: 'Inactive',
          baseUrl: 'https://inactive.invalid',
          chatModel: settings.model,
          reasonerModel: settings.model,
          models: [settings.model],
        ),
      ],
    );
  }

  void publishSettingsIdentity() =>
      state = AsyncData(state.requireValue.copyWith());
  @override
  Future<ModelServiceCredentialSnapshot> readCurrentProfileCredentials(
    String id,
  ) async {
    reads++;
    final settings = state.requireValue;
    final key = id == 'inactive' ? inactiveKey : settings.apiKey;
    final pending = gate;
    if (id == 'inactive' && pending != null) {
      gate = null;
      entered?.complete();
      await pending.future;
    }
    return ModelServiceCredentialSnapshot(
      profile: settings.profiles.firstWhere((p) => p.id == id),
      apiKey: key,
      epoch: 0,
    );
  }
}

class _Host implements DesktopWorkspaceHost {
  bool enabled = false;
  final entered = Completer<void>();
  final gate = Completer<List<DesktopWorkspace>>();
  @override
  bool get supported => enabled;
  @override
  Future<List<DesktopWorkspace>> list() {
    if (!entered.isCompleted) entered.complete();
    return gate.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late AppDatabase db;
  late ControllerBridgeBackend backend;
  late _Credentials credentials;
  late _Host host;
  late String id;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    host = _Host();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
        settingsControllerProvider.overrideWith(_Credentials.new),
        desktopWorkspaceHostProvider.overrideWithValue(host),
      ],
    );
    await container.read(chatControllerProvider.future);
    credentials =
        container.read(settingsControllerProvider.notifier) as _Credentials;
    backend = ControllerBridgeBackend(container);
    id =
        (await backend.invoke('session.new', {
              'title': 'inactive-secret-first',
            }))['session_id']
            as String;
    expect(credentials.reads, 2);
  });
  tearDown(() async {
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    await db.close();
  });
  void title(String value) => container
      .read(chatControllerProvider.notifier)
      .renameConversation(id, value);
  void rotate(String value) {
    credentials.inactiveKey = value;
    container.read(explicitCredentialEpochProvider.notifier).bump('inactive');
  }

  void redacted(Map<String, Object?> snapshot, Iterable<String> keys) {
    final encoded = jsonEncode(snapshot);
    for (final key in keys) {
      expect(encoded, isNot(contains(key)));
    }
    expect((snapshot['session'] as Map)['title'], contains('[REDACTED]'));
  }

  test('unchanged credentials retain the five second read throttle', () async {
    await backend.snapshot(id);
    await backend.snapshot(id);
    expect(credentials.reads, 2);
  });
  test(
    'inactive credential epoch immediately invalidates redaction cache',
    () async {
      rotate('inactive-secret-rotated');
      title('inactive-secret-first inactive-secret-rotated');
      redacted(await backend.snapshot(id), [
        'inactive-secret-first',
        'inactive-secret-rotated',
      ]);
      expect(credentials.reads, 4);
    },
  );
  test(
    'settings identity immediately invalidates cache without an epoch bump',
    () async {
      credentials.inactiveKey = 'identity-secret-rotated';
      credentials.publishSettingsIdentity();
      title('identity-secret-rotated');
      redacted(await backend.snapshot(id), ['identity-secret-rotated']);
      expect(credentials.reads, 4);
    },
  );
  test(
    'rotation during metadata awaits is redacted before the fresh snapshot capture',
    () async {
      host.enabled = true;
      final snapshot = backend.snapshot(id);
      await host.entered.future;
      rotate('metadata-secret-rotated');
      title('metadata-secret-rotated');
      host.gate.complete([]);
      redacted(await snapshot, ['metadata-secret-rotated']);
      expect(credentials.reads, 4);
    },
  );
  test(
    'concurrent callers recheck a rotation occurring during an older credential read',
    () async {
      rotate('inflight-secret-first');
      final entered = credentials.entered = Completer<void>();
      final gate = credentials.gate = Completer<void>();
      final first = backend.snapshot(id);
      await entered.future;
      final second = backend.snapshot(id);
      rotate('inflight-secret-second');
      title('inflight-secret-first inflight-secret-second');
      gate.complete();
      for (final snapshot in await Future.wait([first, second])) {
        redacted(snapshot, ['inflight-secret-first', 'inflight-secret-second']);
      }
      expect(credentials.reads, 6);
    },
  );
}
