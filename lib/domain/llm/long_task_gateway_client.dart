import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/gateway_config.dart';
import '../../data/models.dart';

class LongTaskInputMessage {
  const LongTaskInputMessage({required this.role, required this.text});

  final MessageRole role;
  final String text;
}

class LongTaskSnapshot {
  const LongTaskSnapshot({
    required this.id,
    required this.status,
    this.outputText = '',
    this.progress = 0,
    this.detail,
    this.error,
    this.lastEventId = 0,
  });

  final String id;
  final String status;
  final String outputText;
  final double progress;
  final String? detail;
  final String? error;
  final int lastEventId;

  bool get isPending => status == 'queued' || status == 'running';
  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'cancelled' || status == 'canceled';
  bool get isFailed => status == 'failed' || isCancelled;
}

/// Client for the Expert Chat long-task Gateway.
///
/// The Gateway owns durable files, task execution and output persistence. This
/// client can disappear while a job runs and reconstruct the latest snapshot
/// from the task id after the app starts again.
class LongTaskGatewayClient {
  LongTaskGatewayClient({Dio? dio})
    : _dio =
          dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  final Dio _dio;

  // Public/self-hosted gateways can have a very slow upload path even when
  // health checks and small requests are fast. Budget at least 8 KiB/s plus a
  // minute for proxy buffering, while still honoring the configured timeout.
  static const int _minimumUploadBytesPerSecond = 8 * 1024;
  static const int _uploadGraceSeconds = 60;
  static const int _maximumUploadTimeoutSeconds = 2 * 60 * 60;

  Future<String> uploadFile({
    required GatewayConnection connection,
    required Attachment attachment,
    required CancelToken cancelToken,
  }) async {
    final encoded = attachment.imageBase64;
    if (encoded == null || encoded.isEmpty) {
      throw Exception('附件 ${attachment.name} 没有保留原始文件，无法创建长任务。请重新上传。');
    }
    late final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      throw Exception('附件 ${attachment.name} 的原始数据已损坏，请重新上传。');
    }

    final config = connection.config;
    if (config.hasDedicatedUploadBaseUrl) {
      try {
        return await _uploadOnce(
          connection: connection,
          baseUrl: config.normalizedUploadBaseUrl,
          attachment: attachment,
          bytes: bytes,
          cancelToken: cancelToken,
        );
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) rethrow;
        if (!_isUploadEndpointUnavailable(error)) {
          throw _humanize(error, action: '文件上传');
        }
      }
    }

    try {
      return await _uploadOnce(
        connection: connection,
        baseUrl: config.normalizedBaseUrl,
        attachment: attachment,
        bytes: bytes,
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw _humanize(error, action: '文件上传');
    }
  }

  Future<String> _uploadOnce({
    required GatewayConnection connection,
    required String baseUrl,
    required Attachment attachment,
    required List<int> bytes,
    required CancelToken cancelToken,
  }) async {
    final headers = await _headers(connection, json: false);
    final response = await _dio.post<Map<String, dynamic>>(
      _endpointFromBase(baseUrl, 'files'),
      options: Options(
        headers: headers,
        sendTimeout: _uploadTimeout(connection, bytes.length),
        receiveTimeout: connection.config.requestTimeout,
      ),
      // FormData and MultipartFile are single-use streams. Build them inside
      // each attempt so a direct-endpoint failure can safely retry the bytes.
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: attachment.name,
          contentType: DioMediaType.parse(attachment.mimeType),
        ),
      }),
      cancelToken: cancelToken,
    );
    final id = response.data?['id'] as String?;
    if (id == null || id.trim().isEmpty) {
      throw Exception('文件上传成功，但 Gateway 没有返回文件 ID。');
    }
    return id;
  }

  Future<LongTaskSnapshot> create({
    required GatewayConnection connection,
    required List<LongTaskInputMessage> messages,
    required List<String> fileIds,
    required CancelToken cancelToken,
    required String clientRequestId,
    String? instructions,
  }) async {
    if (fileIds.isEmpty) throw Exception('长任务至少需要一个已上传文件。');
    final prompt = messages
        .lastWhere(
          (message) => message.role == MessageRole.user,
          orElse: () => const LongTaskInputMessage(
            role: MessageRole.user,
            text: '请深入处理这些文件。',
          ),
        )
        .text
        .trim();
    try {
      final options = await _requestOptions(connection);
      final response = await _dio.post<Map<String, dynamic>>(
        _endpoint(connection, 'tasks'),
        options: options,
        data: {
          'prompt': prompt.isEmpty ? '请深入处理这些文件。' : prompt,
          'file_ids': fileIds,
          'client_request_id': clientRequestId,
          if (connection.config.taskModel.trim().isNotEmpty)
            'model': connection.config.taskModel.trim(),
          if (instructions != null && instructions.trim().isNotEmpty)
            'instructions': instructions.trim(),
          'messages': [
            for (final message in messages)
              {
                'role': message.role == MessageRole.assistant
                    ? 'assistant'
                    : 'user',
                'text': message.text,
              },
          ],
        },
        cancelToken: cancelToken,
      );
      return _snapshot(response.data);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw _humanize(error, action: '启动后台任务');
    }
  }

  Future<LongTaskSnapshot> retrieve({
    required GatewayConnection connection,
    required String taskId,
    CancelToken? cancelToken,
  }) async {
    try {
      final options = await _requestOptions(connection);
      final response = await _dio.get<Map<String, dynamic>>(
        _endpoint(connection, 'tasks/$taskId'),
        options: options,
        cancelToken: cancelToken,
      );
      return _snapshot(response.data);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw _humanize(error, action: '查询后台任务');
    }
  }

  Future<void> cancel({
    required GatewayConnection connection,
    required String taskId,
  }) async {
    try {
      final options = await _requestOptions(connection);
      await _dio.post<void>(
        _endpoint(connection, 'tasks/$taskId/cancel'),
        options: options,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode != 409) {
        throw _humanize(error, action: '取消后台任务');
      }
    }
  }

  Future<void> deleteFile({
    required GatewayConnection connection,
    required String fileId,
  }) async {
    try {
      final options = await _requestOptions(connection);
      await _dio.delete<void>(
        _endpoint(connection, 'files/$fileId'),
        options: options,
      );
    } catch (_) {
      // Cleanup does not change an already completed task into a failure.
    }
  }

  static LongTaskSnapshot _snapshot(Map<String, dynamic>? json) {
    if (json == null) throw Exception('Gateway 返回了空任务响应。');
    final id = (json['id'] as String? ?? '').trim();
    if (id.isEmpty) throw Exception('Gateway 没有返回任务 ID。');
    return LongTaskSnapshot(
      id: id,
      status: (json['status'] as String? ?? 'failed').toLowerCase(),
      outputText: json['output_text'] as String? ?? '',
      progress: ((json['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
      detail: json['detail'] as String?,
      error: json['error'] as String?,
      lastEventId: (json['last_event_id'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<Map<String, String>> _headers(
    GatewayConnection connection, {
    bool json = true,
  }) async {
    final token = await connection.resolveApiToken();
    return {
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
    };
  }

  static String _endpoint(GatewayConnection connection, String path) =>
      '${connection.config.normalizedBaseUrl}/v1/$path';

  static String _endpointFromBase(String baseUrl, String path) =>
      '$baseUrl/v1/$path';

  static bool _isUploadEndpointUnavailable(DioException error) {
    if (error.response != null) return false;
    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.connectionError;
  }

  static Future<Options> _requestOptions(GatewayConnection connection) async =>
      Options(
        headers: await _headers(connection),
        sendTimeout: connection.config.requestTimeout,
        receiveTimeout: connection.config.requestTimeout,
      );

  static Duration _uploadTimeout(GatewayConnection connection, int byteCount) {
    final estimatedSeconds =
        ((byteCount + _minimumUploadBytesPerSecond - 1) ~/
            _minimumUploadBytesPerSecond) +
        _uploadGraceSeconds;
    final configuredSeconds = connection.config.requestTimeout.inSeconds;
    final seconds = estimatedSeconds > configuredSeconds
        ? estimatedSeconds
        : configuredSeconds;
    return Duration(
      seconds: seconds.clamp(
        GatewayConfig.minRequestTimeoutSeconds,
        _maximumUploadTimeoutSeconds,
      ),
    );
  }

  static Exception _humanize(DioException error, {required String action}) {
    final status = error.response?.statusCode;
    final data = error.response?.data;
    String? message;
    if (data is Map) {
      final detail = data['detail'] ?? data['message'];
      if (detail is String) message = detail;
    }
    final suffix = message == null || message.trim().isEmpty
        ? ''
        : '：${message.trim()}';
    if (status == 401) return Exception('$action失败：Gateway Token 无效。');
    if (status == 404) return Exception('$action失败：Gateway 接口或任务不存在。');
    if (status == 413) return Exception('$action失败：文件超过 Gateway 限制。');
    if (status == 429) return Exception('$action失败：任务过多，请稍后重试。');
    if (status != null) return Exception('$action失败（$status）$suffix');
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return Exception('$action超时，请检查 Gateway 地址和网络。');
    }
    return Exception('$action失败：${error.message ?? error.type.name}');
  }
}
