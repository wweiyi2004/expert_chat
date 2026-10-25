import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/composer_modes.dart';
import '../../../data/models.dart';
import '../../../domain/llm/llm_provider.dart';
import 'attachment_chip.dart';
import '../../../core/theme.dart';
import '../../../core/prototype_widgets.dart';
import 'composer_popover.dart';
import 'composer_tool_tray.dart';
import 'reasoning_effort_control.dart';

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
    this.workMode = false,
    this.desktopLayout = false,
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
    this.onConversationOptions,
    this.modelPicker,
    this.permissionControl,
    this.workbenchControl,
    this.attachedToolbar,
    this.locationControl,
    this.contextControl,
    this.locationControlBuilder,
    this.permissionControlBuilder,
    this.hasContextUsage = true,
    this.steering = false,
    this.onCancelSteering,
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
  final bool workMode;
  final bool desktopLayout;
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
  final VoidCallback? onConversationOptions;
  final Widget? modelPicker;
  final Widget? workbenchControl;
  final Widget? permissionControl,
      attachedToolbar,
      locationControl,
      contextControl;
  final Widget Function(bool outside)? locationControlBuilder,
      permissionControlBuilder;
  final bool hasContextUsage;
  final bool steering;
  final VoidCallback? onCancelSteering;
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
    _focusNode = FocusNode()..addListener(_onFocusChanged);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  void _onFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _focusNode.removeListener(_onFocusChanged);
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

  BuildContext? _trayContext;
  Future<void> _togglePlus(BuildContext anchor, Widget tray) async {
    if (_plusOpen) {
      _closePlus();
      return;
    }
    setState(() => _plusOpen = true);
    await showComposerPopover<void>(
      anchor,
      width: 420,
      builder: (menu) {
        _trayContext = menu;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: tray,
        );
      },
    );
    _trayContext = null;
    if (mounted) setState(() => _plusOpen = false);
  }

  void _closePlus() {
    final menu = _trayContext;
    _trayContext = null;
    if (menu != null && menu.mounted) Navigator.pop(menu);
    if (_plusOpen && mounted) setState(() => _plusOpen = false);
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
  Widget build(BuildContext context) => LayoutBuilder(builder: _buildComposer);

  Widget _buildComposer(BuildContext context, BoxConstraints constraints) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final phone = media.size.width < 840;
    final narrow = constraints.maxWidth < 620;
    final keyboard = View.of(context).viewInsets.bottom > 0;
    final locationControl =
        widget.locationControlBuilder?.call(narrow) ?? widget.locationControl;
    final permissionControl =
        widget.permissionControlBuilder?.call(narrow) ??
        widget.permissionControl;
    final compactHeight = media.size.height - media.viewInsets.bottom < 720;
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
        minLines: narrow && !keyboard ? 2 : 1,
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
        style: const TextStyle(fontSize: 14, height: 1.5),
        decoration: InputDecoration(
          hintText: widget.steering
              ? '补充方向或验收要求，下一轮生效'
              : widget.workMode
              ? '描述目标、材料和交付要求…'
              : '发消息…',
          isDense: true,
          isCollapsed: true,
          constraints: const BoxConstraints(minHeight: 24),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 2,
          ),
        ),
      ),
    );
    final thinkingControls = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _ComposerToggleChip(
          selected: widget.deepThink,
          icon: Icons.psychology_outlined,
          label: '深度思考',
          onSelected: widget.onToggleDeepThink,
        ),
        Tooltip(
          message: !widget.deepThink
              ? '开启深度思考后可调节'
              : !widget.supportsReasoningEffort
              ? '当前模型不支持调节推理强度'
              : '调节推理强度',
          child: _ComposerToggleChip(
            key: const ValueKey('composer-reasoning-effort-button'),
            selected: widget.deepThink && widget.supportsReasoningEffort,
            icon: Icons.tune_rounded,
            label: '思考档位',
            onSelected:
                widget.deepThink &&
                    widget.supportsReasoningEffort &&
                    widget.onReasoningEffortChanged != null
                ? _showReasoningEffort
                : null,
          ),
        ),
      ],
    );
    final toolTray = ComposerToolTray(
      imageGenerationConfigured: widget.imageGenerationConfigured,
      imageMode: widget.imageMode,
      picking: widget.picking,
      searchMode: widget.searchMode,
      imageGenMode: widget.imageGenMode,
      mcpAvailable: widget.mcpAvailable,
      mcpSelectedCount: widget.mcpSelectedCount,
      documentEditAvailable:
          widget.documentEditAvailable && !widget.isStreaming,
      longTaskAvailable: widget.longTaskAvailable,
      longTaskMode: widget.longTaskMode,
      onConversationOptions: widget.onConversationOptions == null
          ? null
          : () => _runAndClose(widget.onConversationOptions!),
      onVoiceConversation:
          widget.onVoiceConversation == null || widget.isStreaming
          ? null
          : () => _runAndClose(widget.onVoiceConversation!),
      onPickDocuments: canAttachDocs
          ? () => _runAndClose(widget.onPickDocuments)
          : null,
      onPickImages: canAttachImages
          ? () => _runAndClose(widget.onPickImages)
          : null,
      onPickLibrary: () => _runAndClose(widget.onPickLibrary),
      onToggleImageMode: widget.isStreaming
          ? null
          : () => _runAndClose(widget.onToggleImageMode),
      onSetImageGenMode:
          widget.imageGenerationConfigured &&
              !widget.imageMode &&
              !widget.isStudy
          ? widget.onSetImageGenMode
          : null,
      onPickMcpServers: widget.mcpAvailable
          ? () => _runAndClose(widget.onPickMcpServers ?? () {})
          : null,
      onDocumentEdit: widget.documentEditAvailable
          ? () => _runAndClose(widget.onDocumentEdit ?? () {})
          : null,
      onToggleLongTask: widget.longTaskAvailable
          ? widget.onToggleLongTask
          : null,
    );
    final toolMenu = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toolTray,
        if (!widget.hasContextUsage && widget.contextControl != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text('上下文与用量', style: TextStyle(fontSize: 13)),
                ),
                widget.contextControl!,
              ],
            ),
          ),
      ],
    );
    final primaryControls = <Widget>[
      Padding(
        padding: EdgeInsets.zero,
        child: Builder(
          builder: (anchor) => _ComposerPlusButton(
            open: _plusOpen,
            enabled: true,
            picking: widget.picking,
            onPressed: () => _togglePlus(anchor, toolMenu),
          ),
        ),
      ),
      if (!narrow && locationControl != null)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: locationControl,
        ),
      if (!narrow && widget.workbenchControl != null) widget.workbenchControl!,
      if (!narrow && permissionControl != null)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 100),
          child: permissionControl,
        ),
    ];
    final modelControl = widget.modelPicker == null
        ? null
        : ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: narrow
                  ? 360
                  : (constraints.maxWidth - 430).clamp(100.0, 240.0),
            ),
            child: widget.modelPicker!,
          );
    final actionControls = <Widget>[
      ?modelControl,
      if (widget.desktopLayout && widget.modelPicker == null)
        ReasoningEffortControl(
          compact: phone,
          enabled: true,
          thinking: widget.deepThink,
          effort: widget.reasoningEffort,
          supportsEffort: widget.supportsReasoningEffort,
          onToggle: widget.onToggleDeepThink,
          onChanged: widget.onReasoningEffortChanged,
        ),
      if (widget.contextControl != null && widget.hasContextUsage)
        widget.contextControl!,
      Padding(
        padding: const EdgeInsets.only(left: 4),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            final hasContent =
                value.text.trim().isNotEmpty || widget.attachments.isNotEmpty;
            final voice =
                !hasContent ||
                widget.speechBusy ||
                (widget.speechListening && widget.speechUsesCloudAsr);
            return SizedBox.square(
              dimension: phone ? 44 : 32,
              child: Center(
                child: IconButton.filled(
                  key: ValueKey(
                    widget.isStreaming
                        ? 'composer-stop-button'
                        : voice
                        ? 'composer-microphone-button'
                        : 'composer-send-button',
                  ),
                  tooltip: widget.isStreaming
                      ? '停止'
                      : voice
                      ? widget.speechBusy
                            ? widget.speechUsesCloudAsr
                                  ? '正在上传语音；点按取消'
                                  : '正在准备语音输入'
                            : widget.speechListening
                            ? widget.speechUsesCloudAsr
                                  ? '结束录音并识别'
                                  : '停止语音输入'
                            : '语音输入'
                      : '发送',
                  onPressed: widget.isStreaming
                      ? widget.onStop
                      : widget.speechBusy && !widget.speechUsesCloudAsr
                      ? null
                      : () {
                          _closePlus();
                          if (voice) {
                            widget.onToggleSpeech();
                          } else {
                            widget.onSend();
                          }
                        },
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: widget.speechBusy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            widget.isStreaming
                                ? Icons.stop_rounded
                                : voice
                                ? widget.speechListening
                                      ? Icons.mic_rounded
                                      : Icons.mic_none_rounded
                                : Icons.arrow_upward_rounded,
                            key: ValueKey(
                              '${widget.isStreaming}-$voice-${widget.speechListening}',
                            ),
                            size: 19,
                          ),
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(32),
                    maximumSize: const Size.square(32),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor:
                        widget.isStreaming || widget.speechListening
                        ? scheme.errorContainer
                        : scheme.primary,
                    foregroundColor:
                        widget.isStreaming || widget.speechListening
                        ? scheme.onErrorContainer
                        : scheme.onPrimary,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ];
    return Container(
      key: const ValueKey('chat-composer'),
      decoration: BoxDecoration(
        gradient: widget.desktopLayout
            ? null
            : LinearGradient(
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
            constraints: const BoxConstraints(maxWidth: 740),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                phone
                    ? 10
                    : narrow
                    ? 12
                    : 20,
                0,
                phone
                    ? 10
                    : narrow
                    ? 12
                    : 20,
                phone ? 10 : 14,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Thinking controls sit above the input; chat/work stays in the header.
                  // Tool toggles live in the “+” tray.
                  if (widget.attachedToolbar != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                      child: widget.attachedToolbar!,
                    ),
                  if (!widget.desktopLayout && widget.modelPicker == null)
                    Padding(
                      key: const ValueKey('composer-thinking-controls'),
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                      child: thinkingControls,
                    ),
                  if (widget.steering)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '补充任务 · 不会打断当前轮',
                            style: TextStyle(
                              color: AppStatusColors.of(context).running,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: widget.onCancelSteering,
                          child: const Text('取消'),
                        ),
                      ],
                    ),
                  if (narrow &&
                      (locationControl != null || permissionControl != null))
                    Padding(
                      key: const ValueKey('composer-context-row'),
                      padding: EdgeInsets.only(bottom: keyboard ? 0 : 6),
                      child: Row(
                        children: [
                          if (locationControl != null)
                            Expanded(
                              child: SizedBox(
                                height: phone ? 44 : 28,
                                child: locationControl,
                              ),
                            )
                          else
                            const Spacer(),
                          if (widget.workbenchControl != null)
                            widget.workbenchControl!,
                          if (permissionControl != null) ...[
                            const SizedBox(width: 12),
                            permissionControl,
                          ],
                        ],
                      ),
                    ),
                  Container(
                    key: const ValueKey('composer-input-box'),
                    padding: EdgeInsets.symmetric(
                      horizontal: phone ? 10 : 12,
                      vertical: narrow && !keyboard
                          ? 12
                          : phone
                          ? 8
                          : 10,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(phone ? 22 : 18),
                      border: Border.all(
                        color: widget.steering
                            ? AppStatusColors.of(context).running
                            : _focusNode.hasFocus
                            ? Color.lerp(
                                scheme.outlineVariant,
                                scheme.primary,
                                .45,
                              )!
                            : PrototypeColors.of(context).line,
                      ),
                      boxShadow: [
                        if (_focusNode.hasFocus)
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: .14),
                            spreadRadius: 3,
                          ),
                        BoxShadow(
                          color: scheme.shadow.withValues(alpha: .06),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
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
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: narrow && !keyboard ? 12 : 8,
                          ),
                          child: editor,
                        ),
                        if (narrow)
                          Row(
                            key: const ValueKey('composer-input-actions'),
                            children: [
                              primaryControls.first,
                              const SizedBox(width: 12),
                              if (modelControl != null)
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: modelControl,
                                  ),
                                )
                              else
                                const Spacer(),
                              for (final action in actionControls.skip(
                                modelControl == null ? 0 : 1,
                              )) ...[const SizedBox(width: 8), action],
                            ],
                          )
                        else
                          Row(
                            children: [
                              for (
                                var i = 0;
                                i < primaryControls.length;
                                i++
                              ) ...[
                                if (i > 0) const SizedBox(width: 6),
                                primaryControls[i],
                              ],
                              const Spacer(),
                              for (
                                var i = 0;
                                i < actionControls.length;
                                i++
                              ) ...[
                                if (i > 0) const SizedBox(width: 6),
                                actionControls[i],
                              ],
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

  Future<void> _showReasoningEffort() async {
    _focusNode.unfocus();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Center(
          heightFactor: 1,
          child: ReasoningEffortSlider(
            thinking: widget.deepThink,
            effort: widget.reasoningEffort,
            supportsEffort: widget.supportsReasoningEffort,
            onToggle: widget.onToggleDeepThink,
            onChanged: widget.onReasoningEffortChanged,
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
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('composer-plus-button'),
    button: true,
    enabled: enabled,
    label: open ? '收起附件菜单' : '展开附件菜单',
    child: PrototypeChip(
      label: picking ? '…' : '＋',
      tooltip: open ? '收起' : '添加',
      selected: open,
      onPressed: enabled ? onPressed : null,
    ),
  );
}

class _ComposerToggleChip extends StatelessWidget {
  const _ComposerToggleChip({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = onSelected == null
        ? scheme.onSurface.withValues(alpha: 0.38)
        : selected
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      toggled: selected,
      enabled: onSelected != null,
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
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
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
