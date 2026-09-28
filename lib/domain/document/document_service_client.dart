import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:mime/mime.dart';

import '../../data/gateway_config.dart';
import '../mcp/mcp_client.dart';
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

/// Document capability client hosted by the standalone Expert Chat MCP Server.
class DocumentServiceClient {
  DocumentServiceClient({Dio? dio, McpClient? mcp})
    : _mcp = mcp ?? McpClient(dio: dio);

  static const _uploadChunkBytes = 1024 * 1024;
  final McpClient _mcp;

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
    _validateRequest(connection, GatewayCapabilityIds.documentEdit, fileBytes);
    try {
      final sourceId = await _upload(
        connection: connection,
        fileBytes: fileBytes,
        filename: filename,
        cancelToken: cancelToken,
      );
      final called = await _mcp.callTool(
        connection: connection,
        name: 'edit_document',
        arguments: {
          'file_id': sourceId,
          'patch': patch.toJson(),
          if (patch.outputFilename?.trim().isNotEmpty == true)
            'output_filename': patch.outputFilename!.trim(),
        },
        cancelToken: cancelToken,
      );
      return _downloadResult(
        connection: connection,
        result: called,
        fallbackName: patch.outputFilename ?? _defaultEditedName(filename),
        cancelToken: cancelToken,
      );
    } on McpClientException catch (error) {
      throw DocumentServiceException(error.message, code: error.code);
    }
  }

  Future<({String text, DocumentEditResult? file})> callDiscoveredTool({
    required GatewayConnection connection,
    required String name,
    required Map<String, dynamic> arguments,
    CancelToken? cancelToken,
  }) async {
    if (!connection.isConfigured) {
      throw const DocumentServiceException('Expert Chat MCP Server 尚未启用或配置');
    }
    try {
      final called = await _mcp.callTool(
        connection: connection,
        name: name,
        arguments: arguments,
        cancelToken: cancelToken,
      );
      DocumentEditResult? file;
      final resources = called.structuredContent['resources'];
      if (resources is Map && resources['binary'] != null) {
        file = await _downloadResult(
          connection: connection,
          result: called,
          fallbackName: '$name.bin',
          cancelToken: cancelToken,
        );
      }
      if (file == null) {
        final images = called.content
            .where((block) => block['type'] == 'image')
            .toList();
        if (images.length > 1) {
          throw const DocumentServiceException(
            '当前每次 MCP 调用支持一张截图，请让服务每次返回一张图片。',
            code: 'unsupported_images',
          );
        }
        if (images.isNotEmpty) {
          final image = images.single;
          final mime = image['mimeType'];
          final data = image['data'];
          const extensions = {
            'image/png': 'png',
            'image/jpeg': 'jpg',
            'image/webp': 'webp',
          };
          const maxImageBytes = 8 * 1024 * 1024;
          if (mime is! String ||
              !extensions.containsKey(mime) ||
              data is! String ||
              data.isEmpty ||
              data.length > ((maxImageBytes + 2) ~/ 3) * 4) {
            throw const DocumentServiceException(
              'MCP 截图格式不支持或超过 8 MB 上限。',
              code: 'invalid_image',
            );
          }
          late final Uint8List bytes;
          try {
            bytes = base64Decode(data);
          } on FormatException {
            throw const DocumentServiceException(
              'MCP 截图编码无效。',
              code: 'invalid_image',
            );
          }
          if (bytes.length > maxImageBytes ||
              lookupMimeType('', headerBytes: bytes) != mime) {
            throw const DocumentServiceException(
              'MCP 截图内容与格式不符。',
              code: 'invalid_image',
            );
          }
          file = DocumentEditResult(
            bytes: bytes,
            filename: 'mcp-screenshot.${extensions[mime]}',
            contentType: mime,
          );
        }
      }
      var text = called.text;
      if (connection.computerUse) {
        final structured = called.structuredContent;
        final metadata = <String, dynamic>{
          for (final key in [
            'snapshot_id',
            'pid',
            'window_id',
            'window_bounds',
            'screenshot_width',
            'screenshot_height',
            'image_scale',
            'imageScale',
            'scale',
          ])
            if (structured.containsKey(key)) key: structured[key],
          if (structured['elements'] is List)
            'element_handles': [
              for (final element
                  in (structured['elements'] as List).whereType<Map>().take(
                    250,
                  ))
                if (element['element_token'] is String)
                  {
                    'index': element['element_index'],
                    'token': element['element_token'],
                  },
            ],
        };
        if (metadata.isNotEmpty) {
          text = '$text\n当前窗口观察标识（仅用于下一次操作）：${jsonEncode(metadata)}';
        }
      }
      return (text: text, file: file);
    } on McpClientException catch (error) {
      throw DocumentServiceException(error.message, code: error.code);
    }
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
    _validateRequest(
      connection,
      GatewayCapabilityIds.documentConvert,
      fileBytes,
    );
    try {
      final sourceId = await _upload(
        connection: connection,
        fileBytes: fileBytes,
        filename: filename,
        cancelToken: cancelToken,
      );
      final called = await _mcp.callTool(
        connection: connection,
        name: 'convert_document',
        arguments: {
          'file_id': sourceId,
          'target_format': tgt,
          if (outputFilename?.trim().isNotEmpty == true)
            'output_filename': outputFilename!.trim(),
        },
        cancelToken: cancelToken,
      );
      return _downloadResult(
        connection: connection,
        result: called,
        fallbackName: outputFilename?.trim().isNotEmpty == true
            ? outputFilename!.trim()
            : _defaultConvertedName(filename, tgt),
        cancelToken: cancelToken,
      );
    } on McpClientException catch (error) {
      throw DocumentServiceException(error.message, code: error.code);
    }
  }

  static void _validateRequest(
    GatewayConnection connection,
    String capability,
    Uint8List fileBytes,
  ) {
    if (!connection.config.isConfigured) {
      throw const DocumentServiceException('Expert Chat MCP Server 尚未启用或配置');
    }
    if (!connection.config.supports(capability)) {
      throw const DocumentServiceException('当前 MCP Server 未提供所需文档工具');
    }
    if (fileBytes.isEmpty) {
      throw const DocumentServiceException('文件为空', code: 'patch_invalid');
    }
  }

  Future<String> _upload({
    required GatewayConnection connection,
    required Uint8List fileBytes,
    required String filename,
    CancelToken? cancelToken,
  }) async {
    final safeName = filename.trim().isEmpty ? 'input.bin' : filename.trim();
    String? uploadId;
    try {
      final started = await _mcp.callTool(
        connection: connection,
        name: 'begin_upload',
        arguments: {
          'filename': safeName,
          'mime_type': lookupMimeType(safeName) ?? 'application/octet-stream',
          'size_bytes': fileBytes.length,
        },
        cancelToken: cancelToken,
      );
      uploadId = started.structuredContent['upload_id']?.toString();
      if (uploadId == null || uploadId.isEmpty) {
        throw const McpClientException('MCP Server 没有返回 upload_id');
      }
      var offset = 0;
      while (offset < fileBytes.length) {
        final end = (offset + _uploadChunkBytes).clamp(0, fileBytes.length);
        await _mcp.callTool(
          connection: connection,
          name: 'append_upload',
          arguments: {
            'upload_id': uploadId,
            'chunk_base64': base64Encode(fileBytes.sublist(offset, end)),
            'offset': offset,
          },
          cancelToken: cancelToken,
        );
        offset = end;
      }
      final finished = await _mcp.callTool(
        connection: connection,
        name: 'finish_upload',
        arguments: {'upload_id': uploadId},
        cancelToken: cancelToken,
      );
      final fileId = finished.structuredContent['file_id']?.toString();
      if (fileId == null || fileId.isEmpty) {
        throw const McpClientException('MCP Server 没有返回 file_id');
      }
      return fileId;
    } catch (_) {
      if (uploadId != null && uploadId.isNotEmpty) {
        try {
          await _mcp.callTool(
            connection: connection,
            name: 'abort_upload',
            arguments: {'upload_id': uploadId},
          );
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<DocumentEditResult> _downloadResult({
    required GatewayConnection connection,
    required McpToolResult result,
    required String fallbackName,
    CancelToken? cancelToken,
  }) async {
    final structured = result.structuredContent;
    final resources = structured['resources'];
    final resourceMap = resources is Map
        ? Map<String, dynamic>.from(resources)
        : const <String, dynamic>{};
    final uri = resourceMap['binary']?.toString();
    if (uri == null || uri.isEmpty) {
      throw const McpClientException('MCP 工具结果缺少 binary Resource URI');
    }
    final bytes = await _mcp.readBinaryResource(
      connection: connection,
      uri: uri,
      cancelToken: cancelToken,
    );
    if (bytes.isEmpty) {
      throw const McpClientException('MCP Server 返回了空文件');
    }
    return DocumentEditResult(
      bytes: bytes,
      filename: sanitizeDownloadFilename(
        structured['filename']?.toString(),
        fallback: fallbackName,
      ),
      contentType:
          structured['mime_type']?.toString() ?? 'application/octet-stream',
    );
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
}
