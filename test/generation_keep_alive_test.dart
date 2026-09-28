import 'dart:async';

import 'package:expert_chat/domain/notify/generation_keep_alive.dart';
import 'package:expert_chat/domain/notify/generation_notify.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('expert_chat/generation');
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  final calls = <String>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls.clear();
    GenerationNotify.setAppBackground(false);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
      call,
    ) async {
      calls.add('notification:${call.method}');
      return true;
    });
  });

  tearDown(() async {
    await GenerationNotify.onGenerationEnd(
      success: false,
      conversationTitle: '',
      cancelled: true,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      notifications,
      null,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'stop waits for an in-flight start before releasing protection',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'start') {
          started.complete();
          await release.future;
        }
        return null;
      });
      final keepAlive = GenerationKeepAlive();
      final start = keepAlive.start();
      await started.future;
      final stop = keepAlive.stop();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['start']);
      release.complete();
      await Future.wait([start, stop]);
      expect(calls, ['start', 'stop']);
    },
  );

  test('rapid stop and resend ends with protection enabled', () async {
    final keepAlive = GenerationKeepAlive();
    await Future.wait([keepAlive.start(), keepAlive.stop(), keepAlive.start()]);
    expect(calls, ['start', 'stop', 'start']);
    await keepAlive.stop();
  });

  test('a denied start does not prevent cleanup or later starts', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      if (calls.length == 1) throw PlatformException(code: 'start_not_allowed');
      return null;
    });
    final keepAlive = GenerationKeepAlive();
    await keepAlive.start();
    await keepAlive.stop();
    await keepAlive.start();
    expect(calls, ['start', 'stop', 'start']);
    await keepAlive.stop();
  });

  test('background transitions retain protection until completion', () async {
    await GenerationNotify.onGenerationStart();
    expect(calls.first, 'start');
    GenerationNotify.setAppBackground(true);
    GenerationNotify.setAppBackground(false);
    GenerationNotify.setAppBackground(true);
    expect(calls.where((call) => call == 'stop'), isEmpty);
    calls.clear();
    await GenerationNotify.onGenerationEnd(
      success: true,
      conversationTitle: 'test',
    );
    expect(calls.first, 'stop');
    expect(calls, contains('notification:show'));
    expect(
      calls,
      isNot(contains('notification:requestNotificationsPermission')),
    );
    calls.clear();
    await GenerationNotify.onGenerationEnd(
      success: false,
      conversationTitle: '',
      cancelled: true,
    );
    expect(calls, isEmpty);
  });

  test(
    'stopping during startup does not later prompt or leave a service active',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'start') {
          started.complete();
          await release.future;
        }
        return null;
      });
      final start = GenerationNotify.onGenerationStart();
      await started.future;
      final stop = GenerationNotify.onGenerationEnd(
        success: false,
        conversationTitle: '',
        cancelled: true,
      );
      release.complete();
      await Future.wait([start, stop]);
      expect(calls, ['start', 'stop']);
    },
  );
}
