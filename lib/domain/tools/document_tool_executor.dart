import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../data/gateway_config.dart';
import '../../data/models.dart';
import '../chat/error_describe.dart';
import '../document/document_convert.dart';
import '../document/document_edit_tools.dart';
import '../document/document_patch.dart';
import '../document/document_service_client.dart';
import '../llm/llm_provider.dart';
import 'tool_engine.dart' show SearchActivityListener;

/// Executes document tools and discovered MCP tools without owning chat state.
/// Callbacks are bound to the originating turn by the controller. Each request
/// runs once; recovery and permission admission remain with the caller/client.
class DocumentToolExecutor {
  const DocumentToolExecutor({
    required this.getClient,
    required this.isActive,
    required this.onActivity,
    required this.onAttachment,
    required this.onError,
  });

  final DocumentServiceClient Function() getClient;
  final bool Function() isActive;
  final SearchActivityListener onActivity;
  final void Function(Attachment) onAttachment;
  final void Function(String) onError;

  static Attachment _attachment(DocumentEditResult file, String text) =>
      Attachment(
        name: file.filename,
        mimeType: file.contentType,
        sizeBytes: file.bytes.length,
        text: text,
        imageBase64: base64Encode(file.bytes),
      );

  Future<String> callMcp(
    ToolCall call, {
    required String name,
    required GatewayConnection connection,
    required CancelToken cancelToken,
  }) async {
    final exposedName = call.name ?? '';

    final activity = SearchActivity(
      kind: SearchActivityKind.mcp,
      query: exposedName,
      toolName: exposedName,
      toolArguments: call.argumentsJson,
      startedAt: DateTime.now(),
    );
    onActivity(activity);
    Map<String, dynamic> arguments = const {};
    try {
      final trimmed = call.argumentsJson.trim();
      final decoded = jsonDecode(trimmed.isEmpty ? '{}' : trimmed);
      if (decoded is! Map) {
        _finishCapabilityTrace(activity, ok: false, error: '参数必须是对象');
        return 'MCP 工具 $exposedName 参数必须是对象';
      }
      arguments = Map<String, dynamic>.from(decoded);
    } on FormatException catch (error) {
      _finishCapabilityTrace(activity, ok: false, error: error.message);
      return 'MCP 工具 $exposedName 参数不是合法 JSON：${error.message}';
    }
    try {
      if (!isActive() || cancelToken.isCancelled) {
        _finishCapabilityTrace(activity, ok: false, error: '已取消');
        return 'MCP 工具 $name 已取消。';
      }
      final client = getClient();
      final result = await client.callDiscoveredTool(
        connection: connection,
        name: name,
        arguments: arguments,
        cancelToken: cancelToken,
      );
      if (!isActive() || cancelToken.isCancelled) {
        onActivity(
          activity.copyWith(status: SearchActivityStatus.failed, error: '已取消'),
        );
        return 'MCP 工具 $name 已取消。';
      }
      final file = result.file;
      if (file != null) {
        onAttachment(_attachment(file, '（MCP Server 已返回文件，可下载）'));
      }
      final text = result.text.trim();
      final output = text.isNotEmpty
          ? text
          : file != null
          ? 'MCP 工具 $name 已返回文件「${file.filename}」，已附在本轮回复中。'
          : 'MCP 工具 $name 已执行，无文本结果。';
      onActivity(
        activity.copyWith(
          status: SearchActivityStatus.done,
          resultCount: 1,
          resultText: output,
          finishedAt: DateTime.now(),
          items: [if (file != null) SearchActivityItem(title: file.filename)],
        ),
      );
      return output;
    } on DocumentServiceException catch (error) {
      onActivity(
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: (isCancelError(error) || cancelToken.isCancelled)
              ? '已取消'
              : error.message,
        ),
      );
      if (isCancelError(error) || cancelToken.isCancelled) {
        return 'MCP 工具 $name 已取消。';
      }
      onError(error.message);
      return 'MCP 工具 $name 失败：${error.message}';
    } catch (error) {
      onActivity(
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: (isCancelError(error) || cancelToken.isCancelled)
              ? '已取消'
              : describeError(error),
        ),
      );
      if (isCancelError(error) || cancelToken.isCancelled) {
        return 'MCP 工具 $name 已取消。';
      }
      onError(describeError(error));
      return 'MCP 工具 $name 失败：$error';
    }
  }

  SearchActivity _beginCapabilityTrace({
    required ToolCall call,
    required SearchActivityKind kind,
    required String query,
  }) {
    final activity = SearchActivity(
      kind: kind,
      query: query,
      toolName: call.name,
      toolArguments: call.argumentsJson,
    );
    onActivity(activity);
    return activity;
  }

  void _finishCapabilityTrace(
    SearchActivity activity, {
    required bool ok,
    String? error,
    List<SearchActivityItem> items = const [],
  }) {
    onActivity(
      activity.copyWith(
        status: ok ? SearchActivityStatus.done : SearchActivityStatus.failed,
        resultCount: ok ? (items.isEmpty ? 1 : items.length) : 0,
        error: error,
        items: items,
      ),
    );
  }

  String inspect(ToolCall call, {required List<Attachment> sources}) {
    final activity = _beginCapabilityTrace(
      call: call,
      kind: SearchActivityKind.document,
      query: 'inspect_document',
    );
    try {
      final args = DocumentEditTools.parseInspectDocumentArgs(
        call.argumentsJson,
      );
      final source = _pickDocumentSource(sources, args.attachmentName);
      if (source == null) {
        final names = [
          for (final a in sources)
            if (a.isEditableDocument) a.name,
        ];
        _finishCapabilityTrace(activity, ok: false, error: '没有可检查的附件');
        return names.isEmpty
            ? '本轮没有可检查的附件（.xlsx/.docx/.pptx/.txt/.md/.csv/.tsv）。'
            : '找不到附件「${args.attachmentName}」。本轮可用：${names.join("、")}';
      }
      _finishCapabilityTrace(
        activity,
        ok: true,
        items: [SearchActivityItem(title: source.name)],
      );
      return DocumentEditTools.describeAttachmentForInspect(
        name: source.name,
        format: source.documentPatchFormat,
        mimeType: source.mimeType,
        sizeBytes: source.sizeBytes,
        truncated: source.truncated,
        hasBytes: source.hasDownloadableBytes,
        text: source.text,
      );
    } on DocumentPatchException catch (e) {
      _finishCapabilityTrace(activity, ok: false, error: e.message);
      return '检查参数无效：${e.message}';
    }
  }

  Future<String> edit(
    ToolCall call, {
    required bool supported,
    required GatewayConnection connection,
    required List<Attachment> sources,
    required CancelToken cancelToken,
  }) async {
    final activity = _beginCapabilityTrace(
      call: call,
      kind: SearchActivityKind.document,
      query: 'edit_document',
    );
    String fail(String error, String message) {
      _finishCapabilityTrace(activity, ok: false, error: error);
      return message;
    }

    if (!supported) {
      return fail('MCP Server 未配置', 'MCP Server 未配置或不支持文档编辑：请在设置中连接并发现 Tools。');
    }
    try {
      final args = DocumentEditTools.parseEditDocumentArgs(call.argumentsJson);
      final source = _pickDocumentSource(sources, args.attachmentName);
      if (source == null) {
        final names = [
          for (final a in sources)
            if (a.documentPatchFormat != null) a.name,
        ];
        return fail(
          '没有可编辑附件',
          names.isEmpty
              ? '本轮没有可编辑附件（.xlsx/.docx/.pptx/.txt/.md/.csv/.tsv，需重新上传并保留原文件）。'
              : '找不到附件「${args.attachmentName}」。本轮可用：${names.join("、")}',
        );
      }
      if (!source.hasDownloadableBytes) {
        return fail(
          '未保留原始文件',
          '附件「${source.name}」未保留原始文件字节，无法提交 MCP 文档工具。请重新上传。',
        );
      }
      final expectedFormat = source.documentPatchFormat;
      if (expectedFormat != null &&
          args.patch.format.toLowerCase() != expectedFormat) {
        return fail(
          '补丁格式不一致',
          '补丁 format="${args.patch.format}" 与附件「${source.name}」'
              '（$expectedFormat）不一致，请修正后重试。',
        );
      }
      // Truncated attachments only expose a prefix to the model; set_text would
      // rewrite the full server-side file from that partial view and drop the tail.
      if (source.truncated && args.patch.hasSetTextOp) {
        return fail(
          '截断文件禁止整文件覆写',
          '附件「${source.name}」内容已截断（仅前缀进入模型上下文），'
              '禁止使用 set_text 整文件覆写，否则会丢失未展示部分。'
              '请改用 replace_text，或上传更短的文件后重试。',
        );
      }
      late final Uint8List fileBytes;
      try {
        fileBytes = Uint8List.fromList(base64Decode(source.imageBase64!));
      } catch (_) {
        return fail('数据损坏', '附件「${source.name}」数据损坏，无法编辑。');
      }

      if (!isActive() || cancelToken.isCancelled) {
        return fail('已取消', '文档编辑已取消。');
      }
      final client = getClient();
      final result = await client.edit(
        connection: connection,
        fileBytes: fileBytes,
        filename: source.name,
        patch: args.patch,
        cancelToken: cancelToken,
      );
      if (!isActive() || cancelToken.isCancelled) {
        return fail('已取消', '文档编辑已取消。');
      }

      final out = _attachment(result, '（MCP Server 已完成文档修改，可下载）');
      onAttachment(out);
      _finishCapabilityTrace(
        activity,
        ok: true,
        items: [SearchActivityItem(title: result.filename)],
      );
      final kb = (result.bytes.length / 1024).toStringAsFixed(1);
      return '已生成修改后的文件「${result.filename}」（$kb KB），'
          '已附在本轮回复中，请点击附件下载。';
    } on DocumentPatchException catch (e) {
      _finishCapabilityTrace(activity, ok: false, error: e.message);
      return '补丁无效：${e.message}';
    } on DocumentServiceException catch (e) {
      _finishCapabilityTrace(
        activity,
        ok: false,
        error: (isCancelError(e) || cancelToken.isCancelled)
            ? '已取消'
            : e.message,
      );
      if (isCancelError(e) || cancelToken.isCancelled) return '文档编辑已取消。';
      onError(e.message);
      return '文档编辑失败：${e.message}';
    } catch (e) {
      _finishCapabilityTrace(
        activity,
        ok: false,
        error: (isCancelError(e) || cancelToken.isCancelled)
            ? '已取消'
            : describeError(e),
      );
      if (isCancelError(e) || cancelToken.isCancelled) return '文档编辑已取消。';
      onError(describeError(e));
      return '文档编辑失败：$e';
    }
  }

  Future<String> convert(
    ToolCall call, {
    required bool supported,
    required GatewayConnection connection,
    required List<Attachment> sources,
    required CancelToken cancelToken,
  }) async {
    final activity = _beginCapabilityTrace(
      call: call,
      kind: SearchActivityKind.document,
      query: 'convert_document',
    );
    String fail(String error, String message) {
      _finishCapabilityTrace(activity, ok: false, error: error);
      return message;
    }

    if (!supported) {
      return fail('MCP Server 未配置', 'MCP Server 未配置或不支持格式转换：请在设置中连接并发现 Tools。');
    }
    try {
      final args = DocumentEditTools.parseConvertDocumentArgs(
        call.argumentsJson,
      );
      final source = _pickDocumentSource(sources, args.attachmentName);
      if (source == null) {
        final names = [
          for (final a in sources)
            if (a.isEditableDocument) a.name,
        ];
        return fail(
          '没有可转换附件',
          names.isEmpty
              ? '本轮没有可转换附件（.xlsx/.docx/.pptx/.txt/.md/.csv/.tsv，需重新上传）。'
              : '找不到附件「${args.attachmentName}」。本轮可用：${names.join("、")}',
        );
      }
      if (!source.hasDownloadableBytes) {
        return fail('未保留原始文件', '附件「${source.name}」未保留原始文件字节，无法转换。请重新上传。');
      }
      final srcFmt = source.documentPatchFormat;
      if (srcFmt == null) {
        return fail('不是可转换格式', '附件「${source.name}」不是可转换格式。');
      }
      if (!DocumentConvert.canConvert(srcFmt, args.targetFormat)) {
        final targets = DocumentConvert.targetsFor(srcFmt).join(', ');
        return fail(
          '不支持的转换',
          '不支持 $srcFmt → ${args.targetFormat}。'
              '「${source.name}」可转为：$targets',
        );
      }
      late final Uint8List fileBytes;
      try {
        fileBytes = Uint8List.fromList(base64Decode(source.imageBase64!));
      } catch (_) {
        return fail('数据损坏', '附件「${source.name}」数据损坏，无法转换。');
      }

      if (!isActive() || cancelToken.isCancelled) {
        return fail('已取消', '文档转换已取消。');
      }
      final client = getClient();
      final result = await client.convert(
        connection: connection,
        fileBytes: fileBytes,
        filename: source.name,
        targetFormat: args.targetFormat,
        outputFilename: args.outputFilename,
        cancelToken: cancelToken,
      );
      if (!isActive() || cancelToken.isCancelled) {
        return fail('已取消', '文档转换已取消。');
      }

      final out = _attachment(result, '（MCP Server 已完成格式转换，可下载）');
      onAttachment(out);
      _finishCapabilityTrace(
        activity,
        ok: true,
        items: [SearchActivityItem(title: result.filename)],
      );
      final kb = (result.bytes.length / 1024).toStringAsFixed(1);
      return '已将「${source.name}」转换为「${result.filename}」（$kb KB），'
          '已附在本轮回复中，请点击附件右侧下载图标保存。';
    } on DocumentPatchException catch (e) {
      return fail('转换参数无效', '转换参数无效：${e.message}');
    } on DocumentServiceException catch (e) {
      if (isCancelError(e) || cancelToken.isCancelled) {
        return fail('已取消', '文档转换已取消。');
      }
      onError(e.message);
      return fail(e.message, '文档转换失败：${e.message}');
    } catch (e) {
      if (isCancelError(e) || cancelToken.isCancelled) {
        return fail('已取消', '文档转换已取消。');
      }
      onError(describeError(e));
      return fail(describeError(e), '文档转换失败：$e');
    }
  }

  Attachment? _pickDocumentSource(
    List<Attachment> sources,
    String? attachmentName,
  ) {
    final docs = [
      for (final a in sources)
        if (a.documentPatchFormat != null) a,
    ];
    if (docs.isEmpty) return null;
    final want = attachmentName?.trim();
    if (want != null && want.isNotEmpty) {
      for (final a in docs) {
        if (a.name == want || a.name.toLowerCase() == want.toLowerCase()) {
          return a;
        }
      }
      return null;
    }
    if (docs.length == 1) return docs.first;
    for (final a in docs) {
      if (a.isEditableDocument) return a;
    }
    return docs.first;
  }
}
