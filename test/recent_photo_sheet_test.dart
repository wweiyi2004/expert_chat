import 'dart:async';

import 'package:expert_chat/features/chat/widgets/recent_photo_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

void main() {
  const channel = MethodChannel('com.fluttercandies/photo_manager');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Future<Object?> Function(String id, int page) pageLoader;
  Map<dynamic, dynamic>? permissionRequest;
  Map<String, Object> asset(String id) => {
    'id': id,
    'type': 1,
    'width': 100,
    'height': 100,
  };
  setUp(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'requestPermissionExtend':
          permissionRequest = Map.of(call.arguments as Map);
          return PermissionState.authorized.index;
        case 'getAssetPathList':
          expect(call.arguments['onlyAll'], isFalse);
          expect(
            call.arguments['option']['child']['orders'].first['asc'],
            isFalse,
          );
          return {
            'data': [
              {'id': 'all', 'name': 'All', 'isAll': true},
              {'id': 'camera', 'name': 'Camera', 'isAll': false},
              {'id': 'screenshots', 'name': 'Screenshots', 'isAll': false},
            ],
          };
        case 'getAssetListPaged':
          return pageLoader(call.arguments['id'], call.arguments['page']);
        default:
          return null;
      }
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> open(
    WidgetTester tester,
    void Function(RecentPhotoPickResult?) onResult,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                onResult(await showRecentPhotoPicker(context, maxCount: 2));
              },
              child: const Text('选图'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选图'));
    await tester.pumpAndSettle();
  }

  testWidgets('选图只请求图片权限', (tester) async {
    pageLoader = (_, _) async => {'data': []};
    await open(tester, (_) {});
    expect(
      permissionRequest!['androidPermission']['type'],
      RequestType.image.value,
    );
    expect(permissionRequest!['androidPermission']['mediaLocation'], isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    '跨相册保留顺序和上限，忽略旧相册迟到响应',
    (tester) async {
      final delayed = Completer<Object?>();
      pageLoader = (id, page) async => id == 'camera'
          ? delayed.future
          : {
              'data': [asset('$id-1'), asset('$id-2')],
            };
      RecentPhotoPickResult? result;
      await open(tester, (value) => result = value);
      await tester.tap(find.byKey(const ValueKey('all-1')));
      await tester.tap(find.byTooltip('切换相册'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<AssetPathEntity>, '相机'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('切换相册'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<AssetPathEntity>, '截图'),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      delayed.complete({
        'data': [asset('wrong-camera-photo')],
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('wrong-camera-photo')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('screenshots-1')));
      await tester.tap(find.byKey(const ValueKey('screenshots-2')));
      await tester.pump();
      expect(find.text('最多选择 2 张'), findsOneWidget);
      await tester.pump();
      await tester.tap(find.text('下一步 (2)'));
      await tester.pumpAndSettle();
      expect(result!.assets.map((a) => a.id), ['all-1', 'screenshots-1']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    '分页失败可以重试，已有选择不会丢失',
    (tester) async {
      var attempts = 0;
      pageLoader = (id, page) async {
        if (page == 0) {
          return {'data': List.generate(80, (i) => asset('photo-$i'))};
        }
        if (attempts++ == 0) throw PlatformException(code: 'temporary');
        return {
          'data': [asset('photo-80')],
        };
      };
      RecentPhotoPickResult? result;
      await open(tester, (value) => result = value);
      await tester.tap(find.byKey(const ValueKey('photo-0')));
      await tester.tap(find.text('加载更多图片'));
      await tester.pumpAndSettle();
      expect(find.text('加载失败，点击重试'), findsOneWidget);
      expect(find.text('已选 1/2'), findsOneWidget);
      await tester.tap(find.text('加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('加载更多图片'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('photo-80')),
        600,
        scrollable: find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('photo-80')));
      await tester.pump();
      await tester.tap(find.text('下一步 (2)'));
      await tester.pumpAndSettle();
      expect(result!.assets.map((a) => a.id), ['photo-0', 'photo-80']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
