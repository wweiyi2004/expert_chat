import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/composer_modes.dart';
import '../../../data/models.dart';
import '../../../domain/llm/llm_provider.dart';
import 'attachment_chip.dart';
import 'composer_tool_tray.dart';

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.isStreaming,
    required this.deepThink,
    this.reasoningEffort = ReasoningEffort.high,
    this.supportsReasoningEffort = false,
    required this.searchMode,
    required this.imageGenMode,
    required this.attachments,
    required this.picking,
    required this.storyLike,
    this.isStudy = false,
    required this.directorMode,
    required this.canAttachImages,
    required this.imageGenerationConfigured,
    required this.imageMode,
    required this.longTaskMode,
    required this.longTaskAvailable,
    this.maxImageEditReferences = 1,
    this.documentEditAvailable = false,
    required this.speechBusy,
    required this.speechListening,
    required this.speechUsesCloudAsr,
    required this.onToggleDeepThink,
    this.onReasoningEffortChanged,
    required this.onToggleSearch,
    this.mcpAvailable = false,
    this.mcpSelectedCount = 0,
    this.onPickMcpServers,
    required this.onSetImageGenMode,
    required this.onToggleImageMode,
    required this.onToggleLongTask,
    required this.onPickDocuments,
    required this.onPickImages,
    required this.onPickLibrary,
    required this.onPaste,
    required this.onRemoveAttachment,
    required this.onToggleSpeech,
    this.onVoiceConversation,
    required this.onSend,
    this.onDocumentEdit,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool isStreaming;
  final bool deepThink;
  final ReasoningEffort reasoningEffort;
  final bool supportsReasoningEffort;
  final SearchMode searchMode;
  final ImageGenMode imageGenMode;
  final List<Attachment> attachments;
  final bool picking;
  final bool storyLike;
  final bool isStudy;
  final bool directorMode;
  final bool canAttachImages;
  final bool imageGenerationConfigured;
  final bool imageMode;
  final bool longTaskMode;
  final bool longTaskAvailable;
  final int maxImageEditReferences;
  final bool documentEditAvailable;
  final bool speechBusy;
  final bool speechListening;
  final bool speechUsesCloudAsr;
  final VoidCallback onToggleDeepThink;
  final ValueChanged<ReasoningEffort>? onReasoningEffortChanged;
  final VoidCallback onToggleSearch;
  final bool mcpAvailable;
  final int mcpSelectedCount;
  final VoidCallback? onPickMcpServers;
  final ValueChanged<ImageGenMode> onSetImageGenMode;
  final VoidCallback onToggleImageMode;
  final VoidCallback onToggleLongTask;
  final VoidCallback onPickDocuments;
  final VoidCallback onPickImages;
  final VoidCallback onPickLibrary;
  final Future<void> Function() onPaste;
  final ValueChanged<String> onRemoveAttachment;
  final VoidCallback onToggleSpeech;

  /// Opens hands-free voice conversation mode; hidden when null.
  final VoidCallback? onVoiceConversation;
  final VoidCallback onSend;
  final VoidCallback? onDocumentEdit;
  final VoidCallback onStop;

  @override
  State<ChatComposer> createState() => _ComposerState();
}

class _ComposerState extends State<ChatComposer> {
  /// DeepSeek-style expandable “+” tray for upload / image actions.
  bool _plusOpen = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _focusNode.dispose();
    super.dispose();
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!_focusNode.hasFocus) return false;
    if (widget.controller.value.composing.isValid) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyV) return false;
    if (HardwareKeyboard.instance.isAltPressed) return false;
    if (!HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      return false;
    }
    widget.onPaste();
    return true;
  }

  void _togglePlus() {
    if (widget.isStreaming) return;
    setState(() => _plusOpen = !_plusOpen);
  }

  void _closePlus() {
    if (_plusOpen) setState(() => _plusOpen = false);
  }

  void _runAndClose(VoidCallback action) {
    _closePlus();
    action();
  }

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Collapse the tray while a turn is in flight so it doesn't sit open over
    // the stop button / streaming UI.
    if (widget.isStreaming && _plusOpen) {
      _plusOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final phone = media.size.width < 600;
    final compactHeight = media.size.height - media.viewInsets.bottom < 720;
    final hint = widget.imageMode
        ? (widget.attachments.any((a) => a.isImage)
              ? '描述如何修改参考图（图生图）…'
              : '描述要生成的图片；可点 + 上传参考图…')
        : widget.directorMode
        ? '发导演指令，或使用“写下一场 / 续写当前场”…'
        : widget.storyLike
        ? '续写反应，或输入旁白…'
        : '写下你的想法…';
    final canAttachDocs =
        !widget.isStreaming && !widget.picking && !widget.imageMode;
    final canAttachImages =
        !widget.isStreaming &&
        !widget.picking &&
        ((widget.imageMode && widget.imageGenerationConfigured) ||
            (!widget.imageMode && widget.canAttachImages));
    final editor = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (!widget.isStreaming &&
              !widget.speechBusy &&
              !widget.speechListening &&
              !widget.controller.value.composing.isValid) {
            onSendViaWidget();
          }
        },
      },
      child: TextField(
        key: const ValueKey('composer-text-field'),
        controller: widget.controller,
        focusNode: _focusNode,
        minLines: 1,
        maxLines: phone || compactHeight ? 3 : 5,
        readOnly: widget.speechListening,
        textInputAction: TextInputAction.newline,
        onTap: _closePlus,
        contextMenuBuilder: (context, editableTextState) {
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: editableTextState.contextMenuAnchors,
            buttonItems: [
              for (final item in editableTextState.contextMenuButtonItems)
                if (item.type == ContextMenuButtonType.paste)
                  ContextMenuButtonItem(
                    onPressed: () {
                      editableTextState.hideToolbar();
                      widget.onPaste();
                    },
                    type: ContextMenuButtonType.paste,
                  )
                else
                  item,
            ],
          );
        },
        decoration: InputDecoration(
          hintText: hint,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 7,
          ),
        ),
      ),
    );
    final thinkingControls = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _ComposerToggleChip(
            selected: widget.deepThink,
            icon: Icons.psychology_outlined,
            label: '深度思考',
            onSelected: widget.onToggleDeepThink,
          ),
          if (widget.deepThink && widget.supportsReasoningEffort) ...[
            const SizedBox(width: 8),
            _ReasoningEffortSlider(
              value: widget.reasoningEffort,
              onChanged: widget.onReasoningEffortChanged,
            ),
          ],
        ],
      ),
    );
    return Container(
      key: const ValueKey('chat-composer'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.surface.withValues(alpha: 0),
            scheme.surface.withValues(alpha: 0.94),
            scheme.surface,
          ],
          stops: const [0, 0.32, 1],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, compactHeight ? 8 : 13),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 深度思考 stays on the strip. 对话|任务 lives in the top bar.
                  // Tool toggles live in the “+” tray.
                  thinkingControls,
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _plusOpen
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: ComposerToolTray(
                              imageGenerationConfigured:
                                  widget.imageGenerationConfigured,
                              imageMode: widget.imageMode,
                              picking: widget.picking,
                              searchMode: widget.searchMode,
                              imageGenMode: widget.imageGenMode,
                              mcpAvailable: widget.mcpAvailable,
                              mcpSelectedCount: widget.mcpSelectedCount,
                              documentEditAvailable:
                                  widget.documentEditAvailable &&
                                  !widget.isStreaming,
                              longTaskAvailable: widget.longTaskAvailable,
                              longTaskMode: widget.longTaskMode,
                              onPickDocuments: canAttachDocs
                                  ? () => _runAndClose(widget.onPickDocuments)
                                  : null,
                              onPickImages: canAttachImages
                                  ? () => _runAndClose(widget.onPickImages)
                                  : null,
                              onPickLibrary: widget.isStreaming
                                  ? null
                                  : () => _runAndClose(widget.onPickLibrary),
                              onToggleImageMode: widget.isStreaming
                                  ? null
                                  : () =>
                                        _runAndClose(widget.onToggleImageMode),
                              onToggleSearch: widget.storyLike || widget.isStudy
                                  ? null
                                  : widget.onToggleSearch,
                              onSetImageGenMode:
                                  widget.imageGenerationConfigured &&
                                      !widget.imageMode &&
                                      !widget.isStudy
                                  ? widget.onSetImageGenMode
                                  : null,
                              onPickMcpServers: widget.mcpAvailable
                                  ? () => _runAndClose(
                                      widget.onPickMcpServers ?? () {},
                                    )
                                  : null,
                              onDocumentEdit: widget.documentEditAvailable
                                  ? () => _runAndClose(
                                      widget.onDocumentEdit ?? () {},
                                    )
                                  : null,
                              onToggleLongTask: widget.longTaskAvailable
                                  ? widget.onToggleLongTask
                                  : null,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.72),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.shadow.withValues(alpha: 0.08),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.attachments.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                            child: SingleChildScrollView(
                              key: const ValueKey('composer-attachment-strip'),
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (
                                    var i = 0;
                                    i < widget.attachments.length;
                                    i++
                                  )
                                    Padding(
                                      padding: EdgeInsets.only(
                                        right:
                                            i == widget.attachments.length - 1
                                            ? 0
                                            : 6,
                                      ),
                                      child: AttachmentChip(
                                        attachment: widget.attachments[i],
                                        onRemove: () =>
                                            widget.onRemoveAttachment(
                                              widget.attachments[i].id,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (widget.speechListening)
                          Padding(
                            key: const ValueKey('speech-listening-indicator'),
                            padding: const EdgeInsets.fromLTRB(8, 3, 8, 1),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.graphic_eq_rounded,
                                  size: 16,
                                  color: scheme.error,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    // Cloud ASR only transcribes after a second
                                    // mic tap; system ASR streams partial text.
                                    widget.speechUsesCloudAsr
                                        ? '正在录音… 说完后再点麦克风识别（不会自动发送）'
                                        : '正在听… 识别文字不会自动发送',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (phone)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: editor,
                          ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _ComposerPlusButton(
                              open: _plusOpen,
                              enabled: !widget.isStreaming,
                              picking: widget.picking,
                              onPressed: _togglePlus,
                            ),
                            if (phone)
                              const Spacer()
                            else
                              Expanded(child: editor),
                            const SizedBox(width: 4),
                            if (widget.onVoiceConversation != null) ...[
                              IconButton.filledTonal(
                                key: const ValueKey(
                                  'composer-voice-conversation-button',
                                ),
                                onPressed:
                                    widget.isStreaming ||
                                        widget.speechBusy ||
                                        widget.speechListening
                                    ? null
                                    : () {
                                        _closePlus();
                                        widget.onVoiceConversation!();
                                      },
                                icon: const Icon(Icons.headset_mic_rounded),
                                tooltip: '语音对话（说完自动发送并朗读回复）',
                                style: IconButton.styleFrom(
                                  fixedSize: const Size.square(40),
                                  backgroundColor: scheme.secondaryContainer,
                                  foregroundColor: scheme.onSecondaryContainer,
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                            IconButton.filledTonal(
                              key: const ValueKey('composer-microphone-button'),
                              onPressed:
                                  widget.isStreaming ||
                                      (widget.speechBusy &&
                                          !widget.speechUsesCloudAsr)
                                  ? null
                                  : () {
                                      _closePlus();
                                      widget.onToggleSpeech();
                                    },
                              icon: widget.speechBusy
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      widget.speechListening
                                          ? Icons.mic_rounded
                                          : Icons.mic_none_rounded,
                                    ),
                              tooltip: widget.speechBusy
                                  ? widget.speechUsesCloudAsr
                                        ? '正在上传语音；点按取消'
                                        : '正在准备语音输入'
                                  : widget.speechListening
                                  ? widget.speechUsesCloudAsr
                                        ? '结束录音并识别'
                                        : '停止语音输入'
                                  : '语音输入',
                              style: IconButton.styleFrom(
                                fixedSize: const Size.square(40),
                                backgroundColor: widget.speechListening
                                    ? scheme.errorContainer
                                    : scheme.secondaryContainer,
                                foregroundColor: widget.speechListening
                                    ? scheme.onErrorContainer
                                    : scheme.onSecondaryContainer,
                              ),
                            ),
                            const SizedBox(width: 4),
                            widget.isStreaming
                                ? IconButton.filled(
                                    onPressed: widget.onStop,
                                    icon: const Icon(Icons.stop_rounded),
                                    tooltip: '停止',
                                    style: IconButton.styleFrom(
                                      fixedSize: const Size.square(40),
                                      backgroundColor: scheme.errorContainer,
                                      foregroundColor: scheme.onErrorContainer,
                                    ),
                                  )
                                : IconButton.filled(
                                    onPressed: () {
                                      _closePlus();
                                      widget.onSend();
                                    },
                                    icon: const Icon(
                                      Icons.arrow_upward_rounded,
                                    ),
                                    tooltip: '发送',
                                    style: IconButton.styleFrom(
                                      fixedSize: const Size.square(40),
                                      backgroundColor: scheme.primary,
                                      foregroundColor: scheme.onPrimary,
                                    ),
                                  ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void onSendViaWidget() {
    _closePlus();
    widget.onSend();
  }
}

/// Circular “+” control that expands the media tray (DeepSeek-style).
class _ComposerPlusButton extends StatelessWidget {
  const _ComposerPlusButton({
    required this.open,
    required this.enabled,
    required this.picking,
    required this.onPressed,
  });

  final bool open;
  final bool enabled;
  final bool picking;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = open;
    return Semantics(
      key: const ValueKey('composer-plus-button'),
      button: true,
      enabled: enabled,
      label: open ? '收起附件菜单' : '展开附件菜单',
      excludeSemantics: true,
      child: Tooltip(
        message: open ? '收起' : '添加',
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2, right: 2),
          child: Material(
            color: active
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? onPressed : null,
              child: SizedBox(
                width: 36,
                height: 36,
                child: Center(
                  child: picking
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.primary,
                          ),
                        )
                      : AnimatedRotation(
                          turns: open ? 0.125 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: Icon(
                            Icons.add_rounded,
                            size: 22,
                            color: enabled
                                ? (active
                                      ? scheme.onPrimaryContainer
                                      : scheme.onSurfaceVariant)
                                : scheme.onSurface.withValues(alpha: 0.38),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReasoningEffortSlider extends StatelessWidget {
  const _ReasoningEffortSlider({required this.value, this.onChanged});

  final ReasoningEffort value;
  final ValueChanged<ReasoningEffort>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '思考强度 ${value.label}',
      slider: true,
      value: value.label,
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '强度',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
              SizedBox(
                width: 108,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                  ),
                  child: Slider(
                    min: 0,
                    max: 2,
                    divisions: 2,
                    value: value.index.toDouble(),
                    label: value.label,
                    onChanged: onChanged == null
                        ? null
                        : (v) => onChanged!(ReasoningEffort.values[v.round()]),
                  ),
                ),
              ),
              Text(
                value.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposerToggleChip extends StatelessWidget {
  const _ComposerToggleChip({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      toggled: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.75)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onSelected,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
