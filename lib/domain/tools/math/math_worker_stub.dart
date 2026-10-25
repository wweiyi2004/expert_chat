import 'package:dio/dio.dart';

bool get requiresRemoteMath => true;

Future<Map<String, dynamic>> installManagedMath({
  required String pythonExecutable,
  CancelToken? cancelToken,
  void Function(String)? onStage,
}) async => {
  'ok': false,
  'code': 'platform_unavailable',
  'message': '本设备不支持安装本机 Python 后端',
};

Future<Map<String, dynamic>> executeMath(
  Map<String, dynamic> arguments, {
  required String pythonExecutable,
  CancelToken? cancelToken,
}) async => {
  'ok': false,
  'code': 'platform_unavailable',
  'message': '本设备不支持本机 Python 数学后端，请在电脑执行端调用。',
};
