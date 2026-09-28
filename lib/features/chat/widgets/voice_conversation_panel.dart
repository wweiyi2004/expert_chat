import 'package:flutter/material.dart';

import '../controllers/voice_conversation_controller.dart';

/// Replaces the composer while voice conversation mode is on: shows what is
/// happening, what was heard, one large button and an exit.
class VoiceConversationPanel extends StatelessWidget {
  const VoiceConversationPanel({super.key, required this.controller});

  final VoiceConversationController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final (label, hint, icon, color) = switch (controller.phase) {
          VoiceConversationPhase.listening => (
            '正在听',
            '说完停顿一下就会发送；点按可立即发送',
            Icons.mic_rounded,
            scheme.error,
          ),
          VoiceConversationPhase.replying when controller.speaking => (
            '正在说',
            '点按打断并重新说话',
            Icons.volume_up_rounded,
            scheme.primary,
          ),
          VoiceConversationPhase.replying => (
            '正在想',
            '点按打断并重新说话',
            Icons.more_horiz_rounded,
            scheme.primary,
          ),
          VoiceConversationPhase.paused => (
            '已暂停',
            '点按继续对话',
            Icons.play_arrow_rounded,
            scheme.secondary,
          ),
          VoiceConversationPhase.starting || VoiceConversationPhase.off => (
            '准备中',
            '正在打开麦克风',
            Icons.mic_none_rounded,
            scheme.outline,
          ),
        };
        final heard = controller.transcript;
        return SafeArea(
          top: false,
          child: Padding(
            key: const ValueKey('voice-conversation-panel'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.headset_mic_rounded, size: 18, color: color),
                        const SizedBox(width: 8),
                        Text(
                          '语音对话 · $label',
                          style: text.titleSmall?.copyWith(color: color),
                        ),
                        const Spacer(),
                        IconButton(
                          key: const ValueKey('voice-conversation-exit'),
                          onPressed: controller.exit,
                          icon: const Icon(Icons.close_rounded),
                          tooltip: '退出语音对话',
                        ),
                      ],
                    ),
                    if (heard.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8, bottom: 8),
                        child: Text(
                          heard,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: text.bodyLarge,
                        ),
                      ),
                    Semantics(
                      button: true,
                      label: '$label，$hint',
                      child: SizedBox.square(
                        dimension: 72,
                        child:
                            controller.phase == VoiceConversationPhase.starting
                            ? const Padding(
                                padding: EdgeInsets.all(22),
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                ),
                              )
                            : IconButton.filled(
                                key: const ValueKey('voice-conversation-main'),
                                onPressed: controller.tap,
                                iconSize: 34,
                                icon: Icon(icon),
                                style: IconButton.styleFrom(
                                  backgroundColor: color,
                                  foregroundColor: scheme.surface,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        hint,
                        textAlign: TextAlign.center,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
