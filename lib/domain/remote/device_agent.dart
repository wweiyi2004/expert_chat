import '../../platform/services.dart';
import '../llm/llm_provider.dart';
import 'dart:convert';
import 'dart:typed_data';

/// Local channel only; permission and arming are always explicit user actions.
class DeviceAgent {
  Future<void> releaseSession(String sessionId) async {
    await invoke('releaseOwner', {'sessionId': sessionId});
  }

  Future<Map<String, dynamic>> screenshotMetadata(String sessionId) async =>
      Map<String, dynamic>.from(
        await invoke('screenshotInfo', {'sessionId': sessionId}) as Map,
      );

  static const tools = [
    ToolSpec(
      name: 'device_observe',
      description: '读取已获用户授权的 Android 活动界面，返回 revision 与节点 target。不会开启权限或控制。',
      parameters: {
        'type': 'object',
        'properties': {},
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'device_action',
      description:
          '在用户明确开启控制后操作自己的 Android 设备。优先使用最新观察的节点 target，必须使用最新 revision；动作返回新观察。不允许自动启用权限。tapPoint 坐标是物理屏幕像素；截图可缩放，按返回的 physicalPerImageX/Y 将图像坐标换算为物理像素，勿直接套用缩略图坐标。',
      parameters: {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'tap',
              'text',
              'scroll',
              'back',
              'home',
              'openApp',
              'tapPoint',
              'screenshot',
            ],
          },
          'revision': {'type': 'integer'},
          'target': {'type': 'string'},
          'text': {'type': 'string'},
          'package': {'type': 'string'},
          'backward': {'type': 'boolean'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        'required': ['action', 'revision'],
        'additionalProperties': false,
      },
    ),
  ];
  Future<bool> get available async =>
      (await channel.invokeMapMethod<String, dynamic>('status'))?['enabled'] ==
      true;
  Future<bool> get isArmed async =>
      (await channel.invokeMapMethod<String, dynamic>('status'))?['armed'] ==
      true;
  Future<dynamic> executeTool(
    String name,
    Map<String, dynamic> arguments, {
    required String sessionId,
  }) async {
    if (!await isArmed) throw StateError('用户尚未开启本次设备控制');
    if (name == 'device_observe') {
      return jsonEncode(await invoke('observe', {'sessionId': sessionId}));
    }
    final action = arguments['action'];
    if (name != 'device_action' ||
        ![
          'tap',
          'text',
          'scroll',
          'back',
          'home',
          'openApp',
          'tapPoint',
          'screenshot',
        ].contains(action)) {
      throw ArgumentError('Unsupported device tool');
    }
    if (!await isArmed) throw StateError('用户尚未开启本次设备控制');
    final result = await invoke(action as String, {
      ...arguments,
      'sessionId': sessionId,
    });
    return result is Uint8List ? result : jsonEncode(result);
  }

  static const channel = MethodChannel('expert_chat/device_agent');
  Future<Map<String, dynamic>> observe() async => Map<String, dynamic>.from(
    await channel.invokeMapMethod<String, dynamic>('observe') ?? {},
  );
  Future<dynamic> invoke(String method, [Map<String, dynamic>? arguments]) =>
      channel.invokeMethod<dynamic>(method, arguments);
}
