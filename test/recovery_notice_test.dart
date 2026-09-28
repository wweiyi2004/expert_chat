import 'dart:async';
import 'package:dio/dio.dart';
import 'package:expert_chat/domain/errors/app_failure.dart';
import 'package:expert_chat/features/shared/recovery_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'network errors have distinct guidance and omit request/response secrets',
    () {
      for (final entry in {
        401: FailureKind.authentication,
        403: FailureKind.permission,
        404: FailureKind.model,
        429: FailureKind.rateLimit,
        502: FailureKind.serviceUnavailable,
      }.entries) {
        final request = RequestOptions(
          path: 'https://user:password@example.com/v1?token=private',
          headers: {'Authorization': 'Bearer private'},
          data: 'personal conversation',
        );
        final failure = AppFailure.from(
          DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: request,
              statusCode: entry.key,
              data: 'PRIVATE_RESPONSE',
            ),
          ),
        );
        expect(failure.kind, entry.value);
        expect(failure.details, isNot(contains('private')));
        expect(failure.details, isNot(contains('password')));
        expect(failure.details, isNot(contains('personal conversation')));
        expect(failure.details, isNot(contains('PRIVATE_RESPONSE')));
      }
      expect(
        AppFailure.from(Exception('鉴权失败（401）')).kind,
        FailureKind.authentication,
      );
      expect(AppFailure.from(Exception('接口未找到（404）')).kind, FailureKind.model);
    },
  );

  test('diagnostics mask known keys, bearer tokens and URL credentials', () {
    final safe = redactDiagnostics(
      '失败 opaque-key api_key=other-secret Bearer bearer-secret https://name:pass@host/path?token=query-secret#fragment sk-secret-value',
      secrets: ['opaque-key'],
    );
    for (final secret in [
      'opaque-key',
      'other-secret',
      'bearer-secret',
      'name:pass',
      'query-secret',
      'fragment',
      'sk-secret-value',
    ]) {
      expect(safe, isNot(contains(secret)));
    }
  });

  testWidgets('diagnostics stay collapsed and copying uses masked text', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecoveryNotice(
            error: 'internal opaque-key',
            secrets: ['opaque-key'],
          ),
        ),
      ),
    );
    expect(find.textContaining('opaque-key'), findsNothing);
    expect(find.textContaining('internal'), findsNothing);
    await tester.tap(find.text('技术信息'));
    await tester.pumpAndSettle();
    expect(find.text('internal [已隐藏]'), findsOneWidget);
    await tester.tap(find.text('复制技术信息'));
    await tester.pump();
    expect(copied, 'internal [已隐藏]');
  });

  testWidgets('retry cannot be submitted twice and errors remain recoverable', (
    tester,
  ) async {
    var calls = 0;
    final gate = Completer<void>();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecoveryNotice(
              error: TimeoutException('timeout'),
              onRetry: () {
                calls++;
                return gate.future;
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.tap(find.text('正在重试…'));
    expect(calls, 1);
    gate.completeError(Exception('仍然无法连接'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
