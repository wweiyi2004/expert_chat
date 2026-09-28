import 'dart:async';

import 'package:dio/dio.dart';

enum JevFailure {
  timeout,
  cancelled,
  unauthorized,
  rateLimited,
  invalidResponse,
  invalidRequest,
  unavailable,
}

/// Never exposes request headers, user text, or a raw service error.
class JevException implements Exception {
  const JevException(this.failure);
  final JevFailure failure;

  String get message => switch (failure) {
    JevFailure.timeout => 'Jev 请求超时，请稍后重试。',
    JevFailure.cancelled => '已取消 Jev 请求。',
    JevFailure.unauthorized => 'Jev 密钥无效或尚未获得访问权限。',
    JevFailure.rateLimited => 'Jev 请求过于频繁，请稍后重试。',
    JevFailure.invalidResponse => 'Jev 返回的分类结果无效。',
    JevFailure.invalidRequest => '请检查 Jev 密钥、模型及技能选项。',
    JevFailure.unavailable => '暂时无法连接 Jev，请检查网络或服务状态。',
  };

  @override
  String toString() => message;
}

class JevChoice {
  const JevChoice({required this.choice, required this.confidence});
  final String choice;
  final double confidence;
}

/// TypeSafe's native decision API, separate from the text-generation provider.
/// Contract: https://docs.typesafe.ai/api
class JevClient {
  JevClient({Dio? dio}) : _dio = dio ?? Dio();
  final Dio _dio;

  void close() => _dio.close(force: true);

  Future<JevChoice> choose({
    required String apiKey,
    required String model,
    required Object state,
    required String instructions,
    required Map<String, String> criteria,
    CancelToken? cancelToken,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw const JevException(JevFailure.cancelled);
    }
    if (apiKey.trim().isEmpty ||
        model.trim().isEmpty ||
        criteria.isEmpty ||
        criteria.length > 255) {
      throw const JevException(JevFailure.invalidRequest);
    }
    final localCancel = CancelToken();
    var finished = false;
    cancelToken?.whenCancel.then((_) {
      if (!finished && !localCancel.isCancelled) localCancel.cancel();
    });
    try {
      final response = await _dio
          .post<Object?>(
            'https://api.typesafe.ai/v1/systemone',
            data: {
              'model': model.trim(),
              'state': state,
              'questions': {
                'skill': {
                  'type': 'choice',
                  'instructions': instructions,
                  'criteria': criteria,
                },
              },
            },
            options: Options(
              headers: {'Authorization': 'Bearer ${apiKey.trim()}'},
              contentType: Headers.jsonContentType,
              responseType: ResponseType.json,
              followRedirects: false,
              sendTimeout: timeout,
              receiveTimeout: timeout,
            ),
            cancelToken: localCancel,
          )
          .timeout(timeout);
      if (cancelToken?.isCancelled == true) {
        throw const JevException(JevFailure.cancelled);
      }
      final data = response.data;
      final answers = data is Map ? data['answers'] : null;
      final answer = answers is Map ? answers['skill'] : null;
      if (answer is! Map || answer['type'] != 'choice') {
        throw const JevException(JevFailure.invalidResponse);
      }
      final choice = answer['choice'];
      final confidence = answer['confidence'];
      final probabilities = answer['probabilities'];
      if (choice is! String ||
          !criteria.containsKey(choice) ||
          confidence is! num ||
          !confidence.isFinite ||
          confidence < 0 ||
          confidence > 1 ||
          probabilities is! Map ||
          probabilities.length != criteria.length ||
          !criteria.keys.every(probabilities.containsKey) ||
          !probabilities.values.every(
            (p) => p is num && p.isFinite && p >= 0 && p <= 1,
          )) {
        throw const JevException(JevFailure.invalidResponse);
      }
      final total = probabilities.values.fold<double>(
        0,
        (sum, value) => sum + (value as num).toDouble(),
      );
      if ((total - 1).abs() > 0.01) {
        throw const JevException(JevFailure.invalidResponse);
      }
      return JevChoice(choice: choice, confidence: confidence.toDouble());
    } on TimeoutException {
      localCancel.cancel();
      throw const JevException(JevFailure.timeout);
    } on DioException catch (error) {
      if (cancelToken?.isCancelled == true || CancelToken.isCancel(error)) {
        throw const JevException(JevFailure.cancelled);
      }
      throw JevException(switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => JevFailure.timeout,
        _ => switch (error.response?.statusCode) {
          401 || 403 => JevFailure.unauthorized,
          429 => JevFailure.rateLimited,
          400 || 422 => JevFailure.invalidRequest,
          _ => JevFailure.unavailable,
        },
      });
    } on JevException {
      rethrow;
    } catch (_) {
      throw const JevException(JevFailure.invalidResponse);
    } finally {
      finished = true;
    }
  }
}
