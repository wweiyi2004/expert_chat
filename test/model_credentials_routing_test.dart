import 'package:dio/dio.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/llm_http_errors.dart';
import 'package:expert_chat/domain/llm/prioritized_llm_provider.dart';
import 'package:expert_chat/domain/llm/model_route_diagnostics.dart';
import 'package:expert_chat/domain/llm/model_credentials_unavailable.dart';
import 'capability_evolution_test.dart' show FakeLlm;

void main() {
  test(
    'explicit source lock replaces earlier accepted channel and filters candidate failover',
    () async {
      final requests = <String?>[];
      final provider = PrioritizedLlmProvider(
        delegate: FakeLlm((config) async* {
          requests.add(config.profileId);
          yield const ChatChunk(contentDelta: 'ok', finishReason: 'stop');
        }),
        candidates: (config) async => [
          config.copyWith(profileId: 'alpha'),
          config.copyWith(profileId: 'beta'),
        ],
        credentials: (config) async => config,
      );
      const original = LlmConfig(
        baseUrl: 'https://fixture.invalid',
        apiKey: 'fixture',
        model: 'same',
        profileId: 'alpha',
        routingSessionId: 'task',
      );
      await provider.streamChat(config: original, messages: []).toList();
      await provider
          .streamChat(
            config: original.copyWith(profileId: 'beta', lockProfile: true),
            messages: [],
          )
          .toList();
      expect(requests, ['alpha', 'beta']);
    },
  );

  test(
    'cancellation while credentials await prevents any late delegate request',
    () async {
      final entered = Completer<void>(), released = Completer<LlmConfig>();
      var requests = 0;
      final provider = PrioritizedLlmProvider(
        delegate: FakeLlm((_) async* {
          requests++;
          yield const ChatChunk(contentDelta: 'must not start');
        }),
        candidates: (config) async => [config],
        credentials: (config) {
          entered.complete();
          return released.future;
        },
      );
      const config = LlmConfig(
        baseUrl: 'https://unused.invalid',
        apiKey: 'fixture',
        model: 'model',
      );
      final token = CancelToken();
      final result = provider
          .streamChat(config: config, messages: [], cancelToken: token)
          .toList();
      await entered.future;
      token.cancel('root stopped');
      released.complete(config);
      expect(await result, isEmpty);
      expect(requests, 0);
    },
  );
  test(
    'explicit same-profile transport and auth edits update exact pin without channel scan',
    () async {
      final requests = <LlmConfig>[];
      var scans = 0;
      final provider = PrioritizedLlmProvider(
        delegate: FakeLlm((selected) async* {
          requests.add(selected);
          yield const ChatChunk(contentDelta: 'ok', finishReason: 'stop');
        }),
        candidates: (config) async {
          scans++;
          return [config];
        },
        credentials: (config) async => config,
      );
      const initial = LlmConfig(
        baseUrl: 'https://old.invalid',
        apiKey: 'retained-fixture',
        model: 'same-model',
        profileId: 'channel',
        routingSessionId: 'same-route',
      );
      await provider.streamChat(config: initial, messages: []).toList();
      final edited = initial.copyWith(
        baseUrl: 'http://127.0.0.1:1/v1',
        apiFormat: LlmApiFormat.openAiResponses,
        authMode: 'none',
        maxOutputTokens: 222,
      );
      await provider.streamChat(config: edited, messages: []).toList();
      expect(scans, 1);
      expect(requests.last.profileId, 'channel');
      expect(requests.last.routingSessionId, 'same-route');
      expect(requests.last.baseUrl, edited.baseUrl);
      expect(requests.last.apiFormat, LlmApiFormat.openAiResponses);
      expect(requests.last.authMode, 'none');
      expect(requests.last.maxOutputTokens, 222);
    },
  );
  test(
    'explicit secondary key rotation preserves accepted host and routing session after failover',
    () async {
      final requests = <LlmConfig>[];
      var candidateScans = 0;
      final provider = PrioritizedLlmProvider(
        delegate: FakeLlm((selected) async* {
          requests.add(selected);
          if (selected.profileId == 'primary') {
            throw const LlmHttpException('synthetic failure', statusCode: 503);
          }
          yield const ChatChunk(contentDelta: 'ok', finishReason: 'stop');
        }),
        credentials: (selected) async => selected,
        candidates: (config) async {
          candidateScans++;
          return [
            config.copyWith(
              profileId: 'primary',
              baseUrl: 'https://primary.invalid',
              apiKey: 'primary-fixture',
            ),
            config.copyWith(
              profileId: 'secondary',
              baseUrl: 'https://secondary.invalid',
              apiKey: 'old-secondary-fixture',
            ),
          ];
        },
      );
      const initial = LlmConfig(
        baseUrl: 'https://primary.invalid',
        apiKey: 'primary-fixture',
        profileId: 'primary',
        model: 'same-model',
        routingSessionId: 'stable-route',
      );
      final first = await provider
          .streamChat(config: initial, messages: [])
          .toList();
      final accepted = first
          .firstWhere((chunk) => chunk.actualConfig != null)
          .actualConfig!;
      expect(accepted.profileId, 'secondary');
      final rotated = accepted.copyWith(
        apiKey: 'new-secondary-fixture',
        maxOutputTokens: 321,
      );
      await provider.streamChat(config: rotated, messages: []).toList();
      expect(candidateScans, 1);
      expect(requests.map((request) => request.profileId), [
        'primary',
        'secondary',
        'secondary',
      ]);
      expect(requests.last.baseUrl, 'https://secondary.invalid');
      expect(requests.last.apiKey, 'new-secondary-fixture');
      expect(requests.last.routingSessionId, 'stable-route');
      expect(requests.last.maxOutputTokens, 321);
    },
  );
  test(
    'inactive account and refresh network skip before request, accepted channel stays pinned',
    () async {
      final diagnostics = ModelRouteDiagnostics()
        ..addListener(() => throw StateError('observer failure'));
      final requests = <String>[];
      var expired = false;
      final provider = PrioritizedLlmProvider(
        delegate: FakeLlm((selected) async* {
          requests.add(selected.profileId!);
          yield const ChatChunk(contentDelta: 'ok', finishReason: 'stop');
        }),
        candidates: (c) async => [
          c.copyWith(profileId: 'inactive'),
          c.copyWith(profileId: 'refresh-network'),
          c.copyWith(profileId: 'ready'),
        ],
        credentials: (selected) async {
          if (selected.profileId == 'inactive' || expired) {
            throw const ModelCredentialsUnavailable('account_not_signed_in');
          }
          if (selected.profileId == 'refresh-network') {
            throw DioException(
              requestOptions: RequestOptions(path: 'https://auth.invalid'),
              type: DioExceptionType.connectionError,
            );
          }
          return selected;
        },
        diagnostics: diagnostics,
      );
      const config = LlmConfig(
        baseUrl: 'https://not-used.invalid',
        apiKey: 'unused',
        model: 'same-model',
        routingSessionId: 'credential-task',
      );
      await provider.streamChat(config: config, messages: []).toList();
      expect(requests, ['ready']);
      expect(
        diagnostics.events.map((event) => event.outcome),
        containsAll([
          'activation_missing:account_not_signed_in',
          'credential_refresh_failed',
          'accepted',
        ]),
      );
      expired = true;
      await expectLater(
        provider.streamChat(config: config, messages: []).toList(),
        throwsA(isA<ModelCredentialsUnavailable>()),
      );
      expect(requests, ['ready']);
    },
  );
}
