import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../data/models.dart';

/// Renders a [Conversation] to a Markdown document and saves it to a
/// user-chosen location. Pure [toMarkdown] is separated for testing.
class ConversationExport {
  /// Build a Markdown transcript. Reasoning and citations are included so the
  /// export is a faithful record of the session. Only the currently visible
  /// branch ([Conversation.activePath]) is exported — discarded edit/regenerate
  /// branches are left out so the document matches what the user sees.
  ///
  /// Cast/character names come from LLM output; collapse whitespace and
  /// escape Markdown markers so label lines (`_…_`, `## …`) stay intact.
  /// Brackets/parens are escaped too — an unescaped `[x](https://evil.com)`
  /// in a name would render as a clickable link inside the heading.
  static String _inlineLabel(String value) => value
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll('\\', r'\\')
      .replaceAll('_', r'\_')
      .replaceAll('*', r'\*')
      .replaceAll('`', r'\`')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]')
      .replaceAll('(', r'\(')
      .replaceAll(')', r'\)')
      .trim();

  /// Export a subset of messages (multi-select share) as Markdown.
  ///
  /// Order follows [messages] as given (caller should sort by active path).
  static String messagesToMarkdown(
    List<ChatMessage> messages, {
    String title = '所选消息',
    String? characterName,
    bool directorMode = false,
  }) {
    final b = StringBuffer()
      // The title can be a conversation title typed by the user — escape it
      // like any other label so it can't inject Markdown links/headings.
      ..writeln('# ${_inlineLabel(title)}')
      ..writeln()
      ..writeln('_导出时间：${DateTime.now().toIso8601String()}_')
      ..writeln()
      ..writeln('共 ${messages.length} 条消息')
      ..writeln();

    final assistantLabel = () {
      if (directorMode) return '旁白与角色';
      final name = characterName?.trim();
      if (name != null && name.isNotEmpty) return _inlineLabel(name);
      return '助手';
    }();

    for (final m in messages) {
      switch (m.role) {
        case MessageRole.user:
          b.writeln(directorMode ? '## 🎬 导演' : '## 🧑 用户');
          break;
        case MessageRole.assistant:
          final speaker = m.speakerName?.trim();
          b.writeln(
            speaker != null && speaker.isNotEmpty
                ? '## 🤖 ${_inlineLabel(speaker)}'
                : '## 🤖 $assistantLabel',
          );
          break;
        case MessageRole.system:
          b.writeln('## 系统');
          break;
        case MessageRole.tool:
          b.writeln('## 工具');
          break;
      }
      b.writeln();
      if (m.reasoning.trim().isNotEmpty) {
        b
          ..writeln('<details><summary>思考过程</summary>')
          ..writeln()
          ..writeln(m.reasoning.trim())
          ..writeln()
          ..writeln('</details>')
          ..writeln();
      }
      for (final a in m.attachments) {
        final kind = a.isImage ? '图片' : '附件';
        b.writeln(
          '> 📎 $kind：${a.name}'
          '${a.parseError != null ? '（${a.parseError}）' : ''}'
          '${a.remoteUrl != null && a.remoteUrl!.isNotEmpty ? ' · ${a.remoteUrl}' : ''}',
        );
      }
      if (m.content.trim().isNotEmpty) {
        b.writeln(m.content.trim());
      } else if (m.kind == MessageKind.generatedImage &&
          m.attachments.isEmpty) {
        b.writeln('_（生成图，无导出二进制数据）_');
      }
      b.writeln();
    }
    return b.toString();
  }

  /// [characterName] labels assistant turns in story exports.
  static String toMarkdown(Conversation convo, {String? characterName}) {
    final b = StringBuffer()
      ..writeln('# ${_inlineLabel(convo.title)}')
      ..writeln()
      ..writeln('_导出时间：${DateTime.now().toIso8601String()}_');
    if (convo.isStory) {
      if (convo.localCast.isNotEmpty) {
        b
          ..writeln('_模式：导演故事_')
          ..writeln(
            '_AI 角色：'
            '${convo.localCast.map((card) => _inlineLabel(card.name)).join('、')}_',
          );
      } else {
        b.writeln('_模式：故事_');
        final name = characterName?.trim();
        if (name != null && name.isNotEmpty) {
          b.writeln('_角色：${_inlineLabel(name)}_');
        }
      }
      if (convo.outline.trim().isNotEmpty) {
        b
          ..writeln()
          ..writeln('## 大纲')
          ..writeln()
          ..writeln(convo.outline.trim())
          ..writeln()
          ..writeln('进度：${convo.plotCursor}');
      }
      if (convo.authorNote.trim().isNotEmpty) {
        b
          ..writeln()
          ..writeln('## 导演指令')
          ..writeln()
          ..writeln(convo.authorNote.trim());
      }
    }
    b.writeln();

    final assistantLabel = () {
      if (convo.localCast.isNotEmpty) return '旁白与角色';
      final name = characterName?.trim();
      if (name != null && name.isNotEmpty) return _inlineLabel(name);
      return '助手';
    }();

    for (final m in convo.activePath) {
      switch (m.role) {
        case MessageRole.user:
          b.writeln(convo.localCast.isNotEmpty ? '## 🎬 导演' : '## 🧑 用户');
          for (final a in m.attachments) {
            b.writeln(
              '> 📎 ${a.name}'
              '${a.parseError != null ? '（${a.parseError}）' : ''}',
            );
          }
          if (m.content.isNotEmpty) b.writeln(m.content);
        case MessageRole.assistant:
          b.writeln(
            '## 🤖 $assistantLabel'
            '${m.model != null ? ' · `${m.model}`' : ''}',
          );
          if (m.reasoning.trim().isNotEmpty) {
            b
              ..writeln('<details><summary>深度思考</summary>')
              ..writeln()
              ..writeln(m.reasoning)
              ..writeln()
              ..writeln('</details>')
              ..writeln();
          }
          for (final a in m.attachments) {
            final kind = a.isImage ? '图片' : '附件';
            b.writeln(
              '> 📎 $kind：${a.name}'
              '${a.remoteUrl != null && a.remoteUrl!.isNotEmpty ? ' · ${a.remoteUrl}' : ''}',
            );
          }
          if (m.content.isNotEmpty) b.writeln(m.content);
          if (m.citations.isNotEmpty) {
            b.writeln();
            b.writeln('**来源**');
            for (final c in m.citations) {
              b.writeln('${c.index}. [${c.title}](${c.url})');
            }
          }
        case MessageRole.system:
        case MessageRole.tool:
          break; // not part of the visible transcript
      }
      b
        ..writeln()
        ..writeln('---')
        ..writeln();
    }
    return b.toString();
  }

  /// Saves the conversation as a `.md` file via the platform picker. Returns
  /// the saved path on native platforms, the downloaded filename on Web, or
  /// null if the native picker was cancelled. Throws on write failure.
  static Future<String?> saveMarkdown(
    Conversation convo, {
    String? characterName,
  }) async {
    final markdown = toMarkdown(convo, characterName: characterName);
    final bytes = Uint8List.fromList(utf8.encode(markdown));
    final safeTitle = convo.title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final fileName = '${safeTitle.isEmpty ? 'conversation' : safeTitle}.md';

    final isNativeMobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    final path = await FilePicker.saveFile(
      dialogTitle: '导出对话',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['md'],
      // Browser downloads and native mobile need bytes; desktop returns a
      // path that we write ourselves.
      bytes: kIsWeb || isNativeMobile ? bytes : null,
    );
    // Web starts a browser download and has no filesystem path to return.
    if (kIsWeb) return fileName;
    if (path == null) return null;
    if (!isNativeMobile) {
      await File(path).writeAsBytes(bytes);
    }
    return path;
  }
}
