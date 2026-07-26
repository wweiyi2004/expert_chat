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
  static String _inlineLabel(String value) => value
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll('\\', r'\\')
      .replaceAll('_', r'\_')
      .replaceAll('*', r'\*')
      .replaceAll('`', r'\`')
      .trim();

  /// [characterName] labels assistant turns in story exports.
  static String toMarkdown(Conversation convo, {String? characterName}) {
    final b = StringBuffer()
      ..writeln('# ${convo.title}')
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

  /// Saves the conversation as a `.md` file via a native picker. Returns the
  /// saved path, or null if the user cancelled. Throws on write failure.
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

    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    final path = await FilePicker.saveFile(
      dialogTitle: '导出对话',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['md'],
      // Mobile needs bytes to write; desktop returns a path we write ourselves.
      bytes: isMobile ? bytes : null,
    );
    if (path == null) return null;
    if (!isMobile) {
      await File(path).writeAsBytes(bytes);
    }
    return path;
  }
}
