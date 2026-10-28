import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import '../../../platform/browser.dart';

Future<Map<String, String>> authorizeLoopback(
  Uri Function(String) authorize,
  String expectedState,
  CancelToken token,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final callback = 'http://127.0.0.1:${server.port}/auth/callback';
  final result = Completer<Map<String, String>>();
  // Cancellation can arrive while the browser launcher is still pending.
  unawaited(
    result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
  final subscription = server.listen((request) async {
    final values = request.uri.queryParameters;
    if (request.method != 'GET' ||
        request.uri.path != '/auth/callback' ||
        values['state'] != expectedState) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Invalid callback');
      await request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType.html;
    request.response.write(
      '<!doctype html><meta charset="utf-8"><title>Expert Chat</title><p>已收到登录结果，请返回 Expert Chat。</p>',
    );
    await request.response.close();
    if (!result.isCompleted) {
      result.complete({...values, 'redirect_uri': callback});
    }
  });
  token.whenCancel.then((error) {
    if (!result.isCompleted) result.completeError(error);
  });
  try {
    if (token.isCancelled) throw token.cancelError!;
    if (!await launchUrl(
      authorize(callback),
      mode: LaunchMode.externalApplication,
    )) {
      throw StateError('无法打开登录浏览器');
    }
    return await result.future.timeout(const Duration(minutes: 5));
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}
