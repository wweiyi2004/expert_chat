import 'package:flutter/material.dart';

import '../data/story_models.dart';

/// Visual tokens for conversation modes (aligned with product wireframe).
class ModeStyle {
  const ModeStyle._();

  static const Color chat = Color(0xFF1F5C6B);
  static const Color story = Color(0xFFC45C26);
  static const Color ensemble = Color(0xFF5B4B8A);
  static const Color study = Color(0xFF2F6FED);

  static Color color(ConversationMode mode) => switch (mode) {
    ConversationMode.chat => chat,
    ConversationMode.story => story,
    ConversationMode.ensemble => ensemble,
    ConversationMode.study => study,
  };

  static IconData icon(ConversationMode mode, {bool outlined = true}) =>
      switch (mode) {
        ConversationMode.chat =>
          outlined ? Icons.chat_bubble_outline : Icons.chat_bubble,
        ConversationMode.story =>
          outlined ? Icons.auto_stories_outlined : Icons.auto_stories,
        ConversationMode.ensemble =>
          outlined ? Icons.groups_outlined : Icons.groups,
        ConversationMode.study =>
          outlined ? Icons.school_outlined : Icons.school,
      };

  static String label(ConversationMode mode) => switch (mode) {
    ConversationMode.chat => '对话',
    ConversationMode.story => '故事',
    ConversationMode.ensemble => '乱斗',
    ConversationMode.study => '学习',
  };

  static String longLabel(ConversationMode mode) => switch (mode) {
    ConversationMode.chat => '普通对话',
    ConversationMode.story => '角色故事',
    ConversationMode.ensemble => '角色大乱斗',
    ConversationMode.study => '学习会话',
  };
}
