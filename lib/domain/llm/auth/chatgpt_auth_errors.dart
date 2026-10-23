import 'dart:async';
import 'package:dio/dio.dart';

String describeChatGptAuthFailure(Object error) {
  if (error is TimeoutException) return '等待浏览器回调超时。请完成浏览器中的授权，并确认本机回调未被拦截后重试。';
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status == 403)
      return 'OpenAI 返回 HTTP 403，拒绝了当前请求。请检查系统代理是否可用，以及账号/工作区是否允许此次授权。';
    if (status == 401) return 'OpenAI 返回 HTTP 401，授权可能已失效，请重新登录。';
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError) {
      return '连接 OpenAI 失败或超时。软件已跟随系统 HTTP 代理，请确认代理正在运行，且能访问 auth.openai.com 和 api.openai.com。';
    }
    String? code;
    final data = error.response?.data;
    if (data is Map &&
        data['error'] is String &&
        RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(data['error'] as String))
      code = data['error'] as String;
    return 'OpenAI 请求未完成${status == null ? '' : '（HTTP $status）'}${code == null ? '' : '：$code'}。请重新尝试。';
  }
  if (error is StateError) return '${error.message}';
  return '授权处理未完成（${error.runtimeType}），请重试。';
}
