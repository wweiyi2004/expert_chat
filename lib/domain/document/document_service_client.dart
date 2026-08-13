import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../data/gateway_config.dart';
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

/// Document capability client hosted by the unified Expert Chat Gateway.
class DocumentServiceClient {
  DocumentServiceClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<DocumentEditResult> edit({
    required GatewayConnection connection,
    required Uint8List fileBytes,
    required String filename,
    required DocumentPatch patch,
    CancelToken? cancelToken,
  }) async {
    final patchJson = jsonEncode(patch.toJson());
    // Mirror server MAX_PATCH_JSON_BYTES so we fail fast without uploading.
    if (utf8.encode(patchJson).length > DocumentPatch.maxPatchJsonBytes) {
      throw DocumentServiceException(
        '补丁过大（上限 ${DocumentPatch.maxPatchJsonBytes} 字节），'
        '请减少 set_text 内容或 ops 条数',
        code: 'patch_invalid',
      );
    }
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        fileBytes,
        filename: filename.trim().isEmpty ? 'input.xlsx' : filename.trim(),
      ),
      'patch': patchJson,
      'filename': filename.trim().isEmpty ? 'input.xlsx' : filename.trim(),
    });
    return _postFile(
      connection: connection,
      requiredCapability: GatewayCapabilityIds.documentEdit,
      fileBytes: fileBytes,
      path: '/v1/documents/edit',
      form: form,
      fallbackName: patch.outputFilename ?? _defaultEditedName(filename),
      errorVerb: '编辑',
      cancelToken: cancelToken,
    );
  }

  Future<DocumentEditResult> convert({
    required GatewayConnection connection,
    required Uint8List fileBytes,
    required String filename,
    required String targetFormat,
    String? outputFilename,
    CancelToken? cancelToken,
  }) async {
    final tgt = targetFormat.trim().toLowerCase().replaceFirst(
      RegExp(r'^\.'),
      '',
    );
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        fileBytes,
        filename: filename.trim().isEmpty ? 'input.bin' : filename.trim(),
      ),
      'target_format': tgt,
      'filename': filename.trim().isEmpty ? 'input.bin' : filename.trim(),
      if (outputFilename != null && outputFilename.trim().isNotEmpty)
        'output_filename': outputFilename.trim(),
    });
    return _postFile(
      connection: connection,
      requiredCapability: GatewayCapabilityIds.documentConvert,
      fileBytes: fileBytes,
      path: '/v1/documents/convert',
      form: form,
      fallbackName: outputFilename?.trim().isNotEmpty == true
          ? outputFilename!.trim()
          : _defaultConvertedName(filename, tgt),
      errorVerb: '转换',
      cancelToken: cancelToken,
    );
  }

  Future<DocumentEditResult> _postFile({
    required GatewayConnection connection,
    required String requiredCapability,
    required Uint8List fileBytes,
    required String path,
    required FormData form,
    required String fallbackName,
    required String errorVerb,
    CancelToken? cancelToken,
  }) async {
    final config = connection.config;
    if (!config.isConfigured) {
      throw const DocumentServiceException('Expert Chat Gateway 尚未启用或配置');
    }
    if (!config.supports(requiredCapability)) {
      throw const DocumentServiceException('当前 Gateway 未提供所需文档能力');
    }
    if (fileBytes.isEmpty) {
      throw const DocumentServiceException('文件为空', code: 'patch_invalid');
    }
    try {
      final token = await connection.resolveApiToken();
      final r = await _dio.post<List<int>>(
        '${config.normalizedBaseUrl}$path',
        data: form,
        options: Options(
          headers: {
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            'Accept': '*/*',
          },
          responseType: ResponseType.bytes,
          receiveTimeout: config.requestTimeout,
          sendTimeout: config.requestTimeout,
          validateStatus: (s) => s != null && s < 500,
        ),
        cancelToken: cancelToken,
      );

      final status = r.statusCode ?? 0;
      if (status == 401 || status == 403) {
        throw const DocumentServiceException(
          'Gateway 文档能力鉴权失败：请检查 Token',
          code: 'unauthorized',
        );
      }
      if (status >= 400) {
        throw DocumentServiceException(
          _messageFromErrorBody(r.data) ?? '文档$errorVerb失败（$status）',
          code: _codeFromErrorBody(r.data) ?? 'internal',
        );
      }

      final bytes = r.data;
      if (bytes == null || bytes.isEmpty) {
        throw const DocumentServiceException('Gateway 文档能力返回空文件');
      }
      // Never trust Content-Disposition blindly (path traversal / control
      // chars). Fall back to the client-side name when the header is hostile.
      final outName = sanitizeDownloadFilename(
        _filenameFromDisposition(r.headers.value('content-disposition')),
        fallback: fallbackName,
      );
      return DocumentEditResult(
        bytes: Uint8List.fromList(bytes),
        filename: outName,
        contentType:
            r.headers.value(Headers.contentTypeHeader) ??
            'application/octet-stream',
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

  static String _defaultConvertedName(String raw, String targetFormat) {
    final name = raw.trim().isEmpty ? 'file' : raw.trim();
    final dot = name.lastIndexOf('.');
    final stem = (dot > 0) ? name.substring(0, dot) : name;
    final ext = targetFormat.startsWith('.') ? targetFormat : '.$targetFormat';
    return '$stem$ext';
  }

  /// Sanitize a download filename from the document service (or any untrusted
  /// header). Removes path segments and rejects NULs and control characters.
  ///
  /// Returns [fallback] (also sanitized) when [raw] is null/empty/hostile.
  static String sanitizeDownloadFilename(
    String? raw, {
    required String fallback,
  }) {
    final safeFallback = _sanitizeFilenamePart(fallback) ?? 'download.bin';
    final candidate = _sanitizeFilenamePart(raw);
    return candidate ?? safeFallback;
  }

  /// Basename-only sanitize. Returns null when the name is unusable.
  static String? _sanitizeFilenamePart(String? raw) {
    if (raw == null) return null;
    var name = raw.trim();
    if (name.isEmpty) return null;

    // Take the last path segment if a hostile header smuggles separators.
    final slash = name.lastIndexOf('/');
    final backslash = name.lastIndexOf('\\');
    final cut = slash > backslash ? slash : backslash;
    if (cut >= 0) {
      name = name.substring(cut + 1).trim();
    }
    if (name.isEmpty || name == '.' || name == '..') return null;
    if (name.contains('\x00')) return null;
    // Strip C0 controls + DEL (headers can embed \r\n for response splitting).
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) return null;
    if (name.length > DocumentPatch.maxOutputFilenameLength) {
      name = name.substring(0, DocumentPatch.maxOutputFilenameLength);
    }
    return name;
  }

  static String? _filenameFromDisposition(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final star = RegExp(
      r"filename\*=UTF-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(raw);
    if (star != null) {
      try {
        return Uri.decodeComponent(star.group(1)!.trim());
      } on FormatException {
        return null;
      }
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
      return 'Gateway 文档处理超时：请检查网络或增大超时时间';
    }
    if (e.type == DioExceptionType.connectionError) {
      return '无法连接 Gateway：请检查 Base URL 与网络';
    }
    final fromBody = _messageFromErrorBody(e.response?.data);
    if (fromBody != null) return fromBody;
    final status = e.response?.statusCode;
    if (status != null) return 'Gateway 文档请求失败（$status）';
    return 'Gateway 文档请求失败：${e.message ?? e.type.name}';
  }
}
