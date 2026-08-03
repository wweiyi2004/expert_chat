import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../data/document_service_config.dart';
import 'document_patch.dart';

class DocumentEditResult {
  const DocumentEditResult({
    required this.bytes,
    required this.filename,
    this.contentType =
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  });

  final Uint8List bytes;
  final String filename;
  final String contentType;
}

class DocumentServiceException implements Exception {
  const DocumentServiceException(this.message, {this.code = 'internal'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// HTTP client for the Linux document-edit service.
class DocumentServiceClient {
  DocumentServiceClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<Map<String, dynamic>> health({
    required DocumentServiceConfig config,
    CancelToken? cancelToken,
  }) async {
    final base = config.normalizedBaseUrl;
    if (base.isEmpty) {
      throw const DocumentServiceException('未配置文档服务 Base URL');
    }
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '$base/v1/health',
        options: Options(
          receiveTimeout: config.timeout,
          sendTimeout: config.timeout,
          responseType: ResponseType.json,
        ),
        cancelToken: cancelToken,
      );
      return r.data ?? const {};
    } on DioException catch (e) {
      throw DocumentServiceException(_humanize(e));
    }
  }

  Future<DocumentEditResult> edit({
    required DocumentServiceConfig config,
    required String apiToken,
    required Uint8List fileBytes,
    required String filename,
    required DocumentPatch patch,
    CancelToken? cancelToken,
  }) async {
    if (!config.isConfiguredWith(apiToken)) {
      throw const DocumentServiceException(
        '文档服务未完整配置（需启用、Base URL 与 Token）',
      );
    }
    if (fileBytes.isEmpty) {
      throw const DocumentServiceException('文件为空', code: 'patch_invalid');
    }
    // Client-side validate again before upload.
    final body = patch.toJson();
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        fileBytes,
        filename: filename.trim().isEmpty ? 'input.xlsx' : filename.trim(),
      ),
      'patch': jsonEncode(body),
      'filename': filename.trim().isEmpty ? 'input.xlsx' : filename.trim(),
    });

    try {
      final r = await _dio.post<List<int>>(
        '${config.normalizedBaseUrl}/v1/documents/edit',
        data: form,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${apiToken.trim()}',
            'Accept': '*/*',
          },
          responseType: ResponseType.bytes,
          receiveTimeout: config.timeout,
          sendTimeout: config.timeout,
          validateStatus: (s) => s != null && s < 500,
        ),
        cancelToken: cancelToken,
      );

      final status = r.statusCode ?? 0;
      if (status == 401 || status == 403) {
        throw const DocumentServiceException(
          '文档服务鉴权失败：请检查 Token',
          code: 'unauthorized',
        );
      }
      if (status >= 400) {
        throw DocumentServiceException(
          _messageFromErrorBody(r.data) ?? '文档编辑失败（$status）',
          code: _codeFromErrorBody(r.data) ?? 'internal',
        );
      }

      final bytes = r.data;
      if (bytes == null || bytes.isEmpty) {
        throw const DocumentServiceException('文档服务返回空文件');
      }
      final outName =
          _filenameFromDisposition(r.headers.value('content-disposition')) ??
          patch.outputFilename ??
          _defaultEditedName(filename);
      return DocumentEditResult(
        bytes: Uint8List.fromList(bytes),
        filename: outName,
        contentType:
            r.headers.value(Headers.contentTypeHeader) ??
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw DocumentServiceException(_humanize(e));
    }
  }

  static String _defaultEditedName(String raw) {
    final name = raw.trim().isEmpty ? 'file.txt' : raw.trim();
    final dot = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1) {
      final stem = name.substring(0, dot);
      final ext = name.substring(dot);
      return '${stem}_edited$ext';
    }
    return '${name}_edited';
  }

  static String? _filenameFromDisposition(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final star = RegExp(
      r"filename\*=UTF-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(raw);
    if (star != null) {
      return Uri.decodeComponent(star.group(1)!.trim());
    }
    final plain = RegExp(
      r'filename="([^"]+)"|filename=([^;]+)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (plain != null) {
      return (plain.group(1) ?? plain.group(2) ?? '').trim();
    }
    return null;
  }

  static String? _messageFromErrorBody(Object? data) {
    final map = _asErrorMap(data);
    final err = map?['error'];
    if (err is Map && err['message'] is String) {
      return err['message'] as String;
    }
    return null;
  }

  static String? _codeFromErrorBody(Object? data) {
    final map = _asErrorMap(data);
    final err = map?['error'];
    if (err is Map && err['code'] is String) return err['code'] as String;
    return null;
  }

  static Map<String, dynamic>? _asErrorMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is List<int>) {
      try {
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  static String _humanize(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return '文档服务超时：请检查网络或增大超时时间';
    }
    if (e.type == DioExceptionType.connectionError) {
      return '无法连接文档服务：请检查 Base URL 与网络';
    }
    final fromBody = _messageFromErrorBody(e.response?.data);
    if (fromBody != null) return fromBody;
    final status = e.response?.statusCode;
    if (status != null) return '文档服务请求失败（$status）';
    return '文档服务请求失败：${e.message ?? e.type.name}';
  }
}
