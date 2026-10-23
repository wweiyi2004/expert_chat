import 'package:dio/dio.dart';

Future<Map<String, String>> authorizeLoopback(
  Uri Function(String) authorize,
  String expectedState,
  CancelToken token,
) async => throw UnsupportedError('请在桌面或手机应用中登录，网页版本不支持本机回调');
