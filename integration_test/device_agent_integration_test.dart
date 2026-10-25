import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:expert_chat/domain/remote/device_agent.dart';

/// Run only on the isolated ExpertChat_Verification_35 emulator after installing
/// tool/build_android_agent_fixtures.py APKs and granting THIS emulator consent.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'owned two-app observe/action/readback, isolation, screenshot and revoke',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Device Agent verification')),
        ),
      );
      final agent = DeviceAgent();
      final consentDeadline = DateTime.now().add(const Duration(seconds: 60));
      while (!await agent.available &&
          DateTime.now().isBefore(consentDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(
        await agent.available,
        isTrue,
        reason: 'Enable accessibility only on the isolated test emulator',
      );
      await agent.invoke('arm');
      debugPrint(
        'DEVICE_ARM_STATUS ${jsonEncode(await agent.invoke('status'))}',
      );
      const owner = 'isolated-fixture-session';
      Future<Map<String, dynamic>> observe() async {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        return Map<String, dynamic>.from(
          await agent.invoke('observe', {'sessionId': owner}) as Map,
        );
      }

      Future<void> saveScreenshot(String name) async {
        final state = await observe();
        final bytes =
            await agent.invoke('screenshot', {
                  'sessionId': owner,
                  'revision': state['revision'],
                })
                as Uint8List;
        final directory = await getApplicationSupportDirectory();
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(bytes, flush: true);
      }

      Future<Map<String, dynamic>> action(
        String method,
        Map<String, dynamic> observation, [
        Map<String, dynamic> args = const {},
      ]) async {
        var state = observation;
        var selected = {...args};
        for (var attempt = 0; attempt < 5; attempt++) {
          try {
            final result = await agent.invoke(method, {
              'sessionId': owner,
              'revision': state['revision'],
              ...selected,
            });
            return Map<String, dynamic>.from(
              (result as Map)['observation'] as Map,
            );
          } on PlatformException catch (error) {
            if (attempt == 4 ||
                error.code != 'device_action_failed' ||
                !(error.message?.contains('Observation is stale') == true ||
                    error.message?.contains('Active window changed') == true)) {
              rethrow;
            }
            final original = selected['target'] == null
                ? null
                : (state['nodes'] as List).firstWhere(
                    (n) => n['target'] == selected['target'],
                  );
            state = await observe();
            if (original != null) {
              final candidates = (state['nodes'] as List).where(
                (n) =>
                    n['text'] == original['text'] &&
                    n['description'] == original['description'] &&
                    n['editable'] == original['editable'],
              );
              if (candidates.length != 1) rethrow;
              selected['target'] = candidates.single['target'];
            }
          }
        }
        throw StateError('No dispatched action');
      }

      for (final number in [1, 2]) {
        var state = await observe();
        await action('openApp', state, {
          'package': 'com.expertchat.fixture$number',
        });
        state = await observe();
        final appDeadline = DateTime.now().add(const Duration(seconds: 12));
        while (state['package'] != 'com.expertchat.fixture$number' &&
            DateTime.now().isBefore(appDeadline)) {
          state = await observe();
        }
        expect(state['package'], 'com.expertchat.fixture$number');
        if (number == 1) await saveScreenshot('agent-before');
        state = await observe();
        final input =
            (state['nodes'] as List).firstWhere((n) => n['editable'] == true)
                as Map;
        await action('text', state, {
          'target': input['target'],
          'text': 'verified-$number',
        });
        state = await observe();
        final save =
            (state['nodes'] as List).firstWhere(
                  (n) => n['text']?.toString().toLowerCase() == 'save fixture',
                )
                as Map;
        await action('tap', state, {'target': save['target']});
        state = await observe();
        expect(
          (state['nodes'] as List).any(
            (n) => n['text'] == 'Saved: verified-$number',
          ),
          isTrue,
        );
        await expectLater(
          agent.invoke('tap', {
            'sessionId': owner,
            'revision': -1,
            'target': save['target'],
          }),
          throwsA(anything),
        );
        await expectLater(
          agent.invoke('observe', {'sessionId': 'another-session'}),
          throwsA(anything),
        );
        await agent.releaseSession('another-session');
        await expectLater(
          agent.invoke('observe', {'sessionId': 'another-session'}),
          throwsA(anything),
        );
        await agent.releaseSession(owner);
        final next = await agent.invoke('observe', {'sessionId': 'next-task'});
        expect((next as Map)['package'], 'com.expertchat.fixture$number');
        await agent.releaseSession('next-task');
      }
      var state = await observe();
      final scroll =
          (state['nodes'] as List).firstWhere((n) => n['scrollable'] == true)
              as Map;
      await action('scroll', state, {'target': scroll['target']});
      state = await observe();
      expect(
        (state['nodes'] as List).any((n) => n['text'] == 'Row 0'),
        isFalse,
      );
      final screenshot = await agent.invoke('screenshot', {
        'sessionId': owner,
        'revision': state['revision'],
      });
      expect(screenshot, isA<Uint8List>());
      expect((screenshot as Uint8List).take(8), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
      final metadata = await agent.screenshotMetadata(owner);
      final header = ByteData.sublistView(screenshot);
      expect(metadata['imageWidth'], header.getUint32(16));
      expect(metadata['imageHeight'], header.getUint32(20));
      expect(
        (metadata['imageWidth'] as int) <= 2048 &&
            (metadata['imageHeight'] as int) <= 2048,
        isTrue,
      );
      expect(
        (metadata['imageWidth'] as num) *
            (metadata['physicalPerImageX'] as num),
        closeTo(metadata['sourceWidth'] as num, 0.01),
      );
      expect(
        (metadata['imageHeight'] as num) *
            (metadata['physicalPerImageY'] as num),
        closeTo(metadata['sourceHeight'] as num, 0.01),
      );
      expect((state['screen'] as Map)['width'], metadata['sourceWidth']);
      expect((state['screen'] as Map)['height'], metadata['sourceHeight']);
      expect(metadata['displayId'], 0);
      final directory = await getApplicationSupportDirectory();
      await File(
        '${directory.path}/agent-after.png',
      ).writeAsBytes(screenshot, flush: true);
      debugPrint('DEVICE_EVIDENCE_READY');
      debugPrint(
        'DEVICE_READY_STATUS ${jsonEncode(await agent.invoke('status'))}',
      );
      final stopDeadline = DateTime.now().add(const Duration(seconds: 180));
      var stopBoundsReported = false;
      while (await agent.isArmed && DateTime.now().isBefore(stopDeadline)) {
        final notificationState = Map<String, dynamic>.from(
          await agent.invoke('observe', {'sessionId': owner}) as Map,
        );
        final targets = (notificationState['nodes'] as List).where(
          (n) => n['text'] == '立即停止' || n['text'] == 'Expert Chat 设备控制已开启',
        );
        if (!stopBoundsReported &&
            notificationState['package'] == 'com.android.systemui' &&
            targets.isNotEmpty) {
          debugPrint(
            'DEVICE_STOP_BOUNDS ${jsonEncode(targets.first['bounds'])}',
          );
          stopBoundsReported = true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(await agent.isArmed, isFalse);
      expect(
        await agent.available,
        isTrue,
        reason:
            'Notification stop must disarm without suppressing accessibility service',
      );
      await expectLater(
        agent.invoke('home', {
          'sessionId': owner,
          'revision': state['revision'],
        }),
        throwsA(anything),
      );
      await agent.invoke('revoke');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await agent.available, isFalse);
    },
  );
}
