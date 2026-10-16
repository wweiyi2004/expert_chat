import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import '../../../data/custom_tts_voices.dart';
import '../../../data/provider_profile.dart';
import '../../../data/media_api_config.dart';
import '../../../domain/llm/gemini_endpoint.dart';

import 'model_settings_widgets.dart';

class MediaApiSettingsCard extends StatefulWidget {
  const MediaApiSettingsCard({
    super.key,
    required this.title,
    this.description,
    required this.icon,
    required this.config,
    required this.apiKey,
    required this.configured,
    required this.onConfigChanged,
    required this.onApiKeyChanged,
    this.showImageSize = false,
    this.showVoice = false,
    this.showSpeechProtocol = false,
    this.showApiFormat = false,
    this.mimoPreset,
    this.aliyunTtsPreset,
    this.onSpeechProviderSelected,
    this.latestConfig,
  });

  final String title;

  /// Optional one-line note; most cards show only the title.
  final String? description;
  final IconData icon;
  final MediaApiConfig config;
  final String apiKey;
  final bool configured;
  final ValueChanged<MediaApiConfig> onConfigChanged;
  final ValueChanged<String> onApiKeyChanged;
  final bool showImageSize;
  final bool showVoice;
  final bool showSpeechProtocol;
  final bool showApiFormat;
  final MediaApiConfig? mimoPreset;
  final MediaApiConfig? aliyunTtsPreset;
  final Future<void> Function(
    SpeechApiProtocol protocol,
    MediaApiConfig fallback,
  )?
  onSpeechProviderSelected;

  /// Returns the endpoint's most recent config at call time — the provider
  /// state, not the last build snapshot — so rapid same-frame field edits
  /// merge instead of having the second overwrite the first.
  final MediaApiConfig Function()? latestConfig;

  @override
  State<MediaApiSettingsCard> createState() => _OptionalApiCardState();
}

class _OptionalApiCardState extends State<MediaApiSettingsCard> {
  /// Pause before an API-key edit is persisted. Every keystroke resets it, so
  /// intermediate (incomplete) keys are never written to secure storage; only
  /// the value the user settles on lands.
  static const _apiKeySaveDebounce = Duration(milliseconds: 500);

  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _voice;
  late final TextEditingController _voiceDesignPrompt;
  late final TextEditingController _apiKey;
  bool _obscure = true;
  bool _pickingCloneSample = false;
  Timer? _apiKeySaveTimer;

  /// True while [onApiKeyChanged] owes the controller a debounced save.
  /// Guards [didUpdateWidget] from reverting in-flight typing to the last
  /// persisted value.
  bool _apiKeyDirty = false;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController(text: widget.config.baseUrl);
    _model = TextEditingController(text: widget.config.model);
    _voice = TextEditingController(text: widget.config.voice);
    _voiceDesignPrompt = TextEditingController(
      text: widget.config.voiceDesignPrompt,
    );
    _apiKey = TextEditingController(text: widget.apiKey);
  }

  @override
  void didUpdateWidget(MediaApiSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(_baseUrl, widget.config.baseUrl);
    _sync(_model, widget.config.model);
    _sync(_voice, widget.config.voice);
    _sync(_voiceDesignPrompt, widget.config.voiceDesignPrompt);
    if (!_apiKeyDirty) _sync(_apiKey, widget.apiKey);
  }

  void _sync(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _onApiKeyChanged(String value) {
    _apiKeyDirty = true;
    _apiKeySaveTimer?.cancel();
    _apiKeySaveTimer = Timer(_apiKeySaveDebounce, () {
      _commitApiKey(value);
    });
  }

  /// Persists the latest key field immediately (debounce complete or leave).
  void _commitApiKey(String value) {
    _apiKeySaveTimer?.cancel();
    _apiKeySaveTimer = null;
    _apiKeyDirty = false;
    widget.onApiKeyChanged(value);
  }

  MediaApiConfig _fallbackForSpeechProtocol(SpeechApiProtocol protocol) =>
      switch (protocol) {
        SpeechApiProtocol.mimoChatCompletions =>
          widget.mimoPreset ??
              const MediaApiConfig(
                baseUrl: MediaApiConfig.mimoBaseUrl,
                model: MediaApiConfig.mimoTtsModel,
                voice: MediaApiConfig.mimoDefaultVoice,
                speechProtocol: SpeechApiProtocol.mimoChatCompletions,
              ),
        SpeechApiProtocol.aliyunModelStudio =>
          widget.aliyunTtsPreset ??
              const MediaApiConfig(
                baseUrl: MediaApiConfig.aliyunModelStudioBaseUrl,
                model: MediaApiConfig.aliyunQwen3TtsModel,
                voice: MediaApiConfig.aliyunQwen3DefaultVoice,
                speechProtocol: SpeechApiProtocol.aliyunModelStudio,
              ),
        SpeechApiProtocol.openAiAudio => const MediaApiConfig(
          voice: '',
          speechProtocol: SpeechApiProtocol.openAiAudio,
        ),
      };

  Future<void> _switchSpeechProvider(
    SpeechApiProtocol protocol, {
    MediaApiConfig? fallback,
  }) async {
    // A provider switch is also a settle point for debounced key editing. Save
    // the current field before changing profiles so the key cannot land in
    // the newly selected provider's secure-storage slot.
    if (_apiKeyDirty) _commitApiKey(_apiKey.text);
    final target = fallback ?? _fallbackForSpeechProtocol(protocol);
    final select = widget.onSpeechProviderSelected;
    if (select != null) {
      await select(protocol, target);
    } else {
      widget.onConfigChanged(target);
    }
  }

  /// Flush any in-flight key edit so leaving the card/page cannot drop it.
  ///
  /// Debounce still avoids writing every intermediate keystroke while the
  /// user is actively typing; dispose / category switch is the settle point.
  ///
  /// The actual write is deferred with [scheduleMicrotask]: calling the
  /// settings controller *during* [dispose] can hit an unmounted Riverpod
  /// ref when the whole tree is tearing down, and can also assert if a
  /// parent rebuild is interleaved with the unmount walk.
  void _flushPendingApiKey() {
    if (!_apiKeyDirty) {
      _apiKeySaveTimer?.cancel();
      _apiKeySaveTimer = null;
      return;
    }
    final value = _apiKey.text;
    final commit = widget.onApiKeyChanged;
    _apiKeySaveTimer?.cancel();
    _apiKeySaveTimer = null;
    _apiKeyDirty = false;
    scheduleMicrotask(() {
      try {
        commit(value);
      } catch (_) {
        // Settings provider already disposed (app/test teardown).
      }
    });
  }

  @override
  void dispose() {
    _flushPendingApiKey();
    _baseUrl.dispose();
    _model.dispose();
    _voice.dispose();
    _voiceDesignPrompt.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _patch({
    String? baseUrl,
    String? model,
    String? imageSize,
    String? voice,
    String? voiceDesignPrompt,
    String? voiceClonePath,
    SpeechApiProtocol? speechProtocol,
    LlmApiFormat? apiFormat,
  }) {
    // Merge against the latest provider state rather than the last build
    // snapshot: two field edits landing in the same frame would otherwise
    // have the second overwrite the first.
    final current = (widget.latestConfig ?? () => widget.config)();
    final nextBaseUrl = baseUrl ?? current.baseUrl;
    final nextModel = model ?? current.model;
    // When the user pastes a MiMo URL/model on the TTS card, upgrade the
    // wire protocol automatically so requests do not hit /audio/speech.
    final nextProtocol =
        speechProtocol ??
        (widget.showSpeechProtocol
            ? MediaApiConfig.inferSpeechProtocol(
                baseUrl: nextBaseUrl,
                model: nextModel,
                current: current.speechProtocol,
              )
            : current.speechProtocol);
    var nextVoice = voice ?? current.voice;
    final nextConfigShape = MediaApiConfig(
      baseUrl: nextBaseUrl,
      model: nextModel,
      speechProtocol: nextProtocol,
    );
    if (nextProtocol != current.speechProtocol) {
      // Link the voice to the wire protocol, but only when it still holds
      // the *other* protocol's default: a MiMo-default voice must never
      // leak into OpenAI /audio/speech requests, and an empty / OpenAI
      // default voice becomes mimo_default on MiMo. A voice the user
      // picked (anything else) is kept untouched.
      final trimmedVoice = current.voice.trim();
      if (nextProtocol == SpeechApiProtocol.openAiAudio &&
          (trimmedVoice == MediaApiConfig.mimoDefaultVoice ||
              MediaApiConfig.mimoBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.aliyunQwen3BuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.aliyunQwenAudioBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ))) {
        // Empty = "use the endpoint default" (the gateway falls back to
        // `alloy`), which the helper text below explains.
        nextVoice = '';
      } else if (nextProtocol == SpeechApiProtocol.mimoChatCompletions &&
          (trimmedVoice.isEmpty ||
              trimmedVoice == MediaApiConfig.openAiDefaultVoice ||
              MediaApiConfig.openAiBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.aliyunQwen3BuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.aliyunQwenAudioBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ))) {
        nextVoice = MediaApiConfig.mimoDefaultVoice;
      } else if (nextProtocol == SpeechApiProtocol.aliyunModelStudio &&
          (trimmedVoice.isEmpty ||
              trimmedVoice == MediaApiConfig.mimoDefaultVoice ||
              MediaApiConfig.mimoBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.openAiBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ))) {
        nextVoice = nextConfigShape.aliyunDefaultVoice;
      }
    } else if (nextProtocol == SpeechApiProtocol.aliyunModelStudio &&
        nextModel != current.model &&
        current.aliyunBuiltinVoices.any(
          (option) => option.id == current.voice.trim(),
        ) &&
        !nextConfigShape.aliyunBuiltinVoices.any(
          (option) => option.id == current.voice.trim(),
        )) {
      // A system voice belongs to one Alibaba model family only. When the
      // model changes, swap that known preset for the new family's default;
      // keep truly custom clone/design IDs untouched.
      nextVoice = nextConfigShape.aliyunDefaultVoice;
    }
    widget.onConfigChanged(
      current.copyWith(
        baseUrl: baseUrl,
        model: model,
        imageSize: imageSize,
        voice: nextVoice,
        voiceDesignPrompt: voiceDesignPrompt,
        voiceClonePath: voiceClonePath,
        speechProtocol: nextProtocol,
        apiFormat: apiFormat,
      ),
    );
  }

  void _selectMimoTtsMode(MimoTtsMode mode) {
    final current = (widget.latestConfig ?? () => widget.config)();
    final nextModel = MediaApiConfig.modelForMimoTtsMode(mode, current.model);
    var nextVoice = current.voice;
    if (mode == MimoTtsMode.builtin &&
        (nextVoice.trim().isEmpty ||
            nextVoice.trim().startsWith('data:') ||
            MediaApiConfig.openAiBuiltinVoices.any(
              (v) => v.id == nextVoice.trim(),
            ))) {
      nextVoice = MediaApiConfig.mimoDefaultVoice;
    }
    _patch(
      model: nextModel,
      voice: nextVoice,
      speechProtocol: SpeechApiProtocol.mimoChatCompletions,
    );
  }

  void _selectAliyunTtsModel(String model) {
    final current = (widget.latestConfig ?? () => widget.config)();
    final target = MediaApiConfig(
      baseUrl: current.baseUrl,
      model: model,
      speechProtocol: SpeechApiProtocol.aliyunModelStudio,
    );
    final selectedVoice = current.voice.trim();
    final isKnownProviderVoice =
        MediaApiConfig.openAiBuiltinVoices.any(
          (option) => option.id == selectedVoice,
        ) ||
        MediaApiConfig.mimoBuiltinVoices.any(
          (option) => option.id == selectedVoice,
        ) ||
        MediaApiConfig.aliyunQwen3BuiltinVoices.any(
          (option) => option.id == selectedVoice,
        ) ||
        MediaApiConfig.aliyunQwenAudioBuiltinVoices.any(
          (option) => option.id == selectedVoice,
        );
    final nextVoice = selectedVoice.isEmpty || isKnownProviderVoice
        ? target.aliyunDefaultVoice
        : selectedVoice;
    _patch(
      // Qwen3-TTS uses public DashScope. Qwen-Audio/CosyVoice keep the current
      // base so users can paste their workspace-scoped domain once.
      baseUrl: target.isAliyunQwen3TtsModel
          ? MediaApiConfig.aliyunModelStudioBaseUrl
          : current.baseUrl,
      model: model,
      voice: nextVoice,
      speechProtocol: SpeechApiProtocol.aliyunModelStudio,
    );
  }

  Future<void> _pickVoiceCloneSample() async {
    if (_pickingCloneSample || kIsWeb) return;
    setState(() => _pickingCloneSample = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mp3', 'wav', 'mpeg'],
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      final sourcePath = picked.path;
      if (sourcePath == null || sourcePath.isEmpty) return;

      final source = File(sourcePath);
      if (!await source.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('无法读取所选音频文件。')));
        }
        return;
      }
      final size = await source.length();
      if (size > 7 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('样本过大，请选择不超过约 7 MB 的 mp3/wav。')),
          );
        }
        return;
      }

      final support = await getApplicationSupportDirectory();
      final dir = Directory(
        '${support.path}${Platform.pathSeparator}tts-voice-clone',
      );
      await dir.create(recursive: true);
      final name = picked.name.toLowerCase();
      final ext = name.endsWith('.mp3') || name.endsWith('.mpeg')
          ? 'mp3'
          : 'wav';
      final dest = File('${dir.path}${Platform.pathSeparator}user-voice.$ext');
      await source.copy(dest.path);
      _selectMimoTtsMode(MimoTtsMode.clone);
      _patch(voiceClonePath: dest.path, voice: '');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已保存用户音色样本：${picked.name}')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入音色样本失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _pickingCloneSample = false);
    }
  }

  Future<void> _clearVoiceCloneSample() async {
    final path = widget.config.voiceClonePath.trim();
    if (path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best effort — missing file is fine.
      }
    }
    _patch(voiceClonePath: '');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(widget.icon, color: scheme.primary),
        title: Text(widget.title),
        subtitle: widget.description == null ? null : Text(widget.description!),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: widget.configured
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                widget.configured ? '已启用' : '未配置',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: widget.configured
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        children: [
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.example.com/v1',
            ),
            onChanged: (value) => _patch(baseUrl: value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '模型',
              hintText: '输入服务商提供的模型 ID',
            ),
            onChanged: (value) => _patch(model: value),
          ),
          if (widget.showApiFormat) ...[
            const SizedBox(height: 12),
            Builder(
              builder: (context) {
                final autoResolved = GeminiEndpoint.resolveFormat(
                  format: LlmApiFormat.auto,
                  baseUrl: widget.config.baseUrl,
                );
                final effective = widget.config.effectiveApiFormat;
                final helper = effective == LlmApiFormat.geminiNative
                    ? (widget.showImageSize
                          ? '使用 Gemini 原生生图协议 (:generateContent / :predict)'
                          : '使用 Gemini 原生多模态协议 (/v1beta/models)')
                    : GeminiEndpoint.isGoogleGeminiHost(widget.config.baseUrl)
                    ? '已自动映射到 Gemini OpenAI 兼容路径 (/v1beta/openai)'
                    : null;
                return DropdownButtonFormField<LlmApiFormat>(
                  key: ValueKey(
                    'media-api-format-${widget.config.apiFormat.name}-${autoResolved.name}',
                  ),
                  initialValue: widget.config.apiFormat,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '接口格式',
                    helperText: helper,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: LlmApiFormat.auto,
                      child: Text(
                        '自动识别（当前：${autoResolved.shortLabel}）',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: LlmApiFormat.openAiCompatible,
                      child: Text(
                        LlmApiFormat.openAiCompatible.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: LlmApiFormat.geminiNative,
                      child: Text(
                        LlmApiFormat.geminiNative.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) _patch(apiFormat: value);
                  },
                );
              },
            ),
          ],
          if (widget.showSpeechProtocol) ...[
            const SizedBox(height: 12),
            // Keyed by protocol so auto-inference / MiMo preset remounts the
            // field; FormField initialValue alone would keep a stale choice.
            DropdownButtonFormField<SpeechApiProtocol>(
              key: ValueKey(
                'speech-protocol-${widget.config.effectiveSpeechProtocol.name}',
              ),
              initialValue: widget.config.effectiveSpeechProtocol,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: '语音 API 协议',
                helperText: widget.config.looksLikeMimoSpeechEndpoint
                    ? '已根据 MiMo 地址/模型自动选用 /chat/completions'
                    : widget.config.looksLikeAliyunSpeechEndpoint
                    ? '已根据百炼地址/模型自动选用 Model Studio HTTP API'
                    : null,
              ),
              items: const [
                DropdownMenuItem(
                  value: SpeechApiProtocol.openAiAudio,
                  child: Text(
                    'OpenAI /audio/speech',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: SpeechApiProtocol.mimoChatCompletions,
                  child: Text(
                    'MiMo /chat/completions（WAV）',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: SpeechApiProtocol.aliyunModelStudio,
                  child: Text(
                    '阿里百炼 Model Studio TTS',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (value) {
                if (value != null) _switchSpeechProvider(value);
              },
            ),
          ],
          if (widget.showVoice &&
              widget.config.effectiveSpeechProtocol ==
                  SpeechApiProtocol.aliyunModelStudio) ...[
            const SizedBox(height: 12),
            _buildAliyunModelPresets(context),
          ],
          if (widget.showVoice) ...[
            const SizedBox(height: 12),
            _buildVoiceSection(context),
          ],
          if (widget.showImageSize) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue:
                  const [
                    '1024x1024',
                    '1536x1024',
                    '1024x1536',
                    'auto',
                  ].contains(widget.config.imageSize)
                  ? widget.config.imageSize
                  : '1024x1024',
              decoration: const InputDecoration(labelText: '图片尺寸'),
              items: const [
                DropdownMenuItem(
                  value: '1024x1024',
                  child: Text('1024 × 1024'),
                ),
                DropdownMenuItem(
                  value: '1536x1024',
                  child: Text('1536 × 1024'),
                ),
                DropdownMenuItem(
                  value: '1024x1536',
                  child: Text('1024 × 1536'),
                ),
                DropdownMenuItem(value: 'auto', child: Text('自动')),
              ],
              onChanged: (value) {
                if (value != null) _patch(imageSize: value);
              },
            ),
          ],
          if (widget.mimoPreset != null || widget.aliyunTtsPreset != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (widget.aliyunTtsPreset != null)
                    FilledButton.tonalIcon(
                      onPressed: () => _switchSpeechProvider(
                        SpeechApiProtocol.aliyunModelStudio,
                        fallback: widget.aliyunTtsPreset!,
                      ),
                      icon: const Icon(Icons.graphic_eq_outlined),
                      label: const Text('切换到百炼 TTS'),
                    ),
                  if (widget.mimoPreset != null)
                    OutlinedButton.icon(
                      onPressed: () => _switchSpeechProvider(
                        SpeechApiProtocol.mimoChatCompletions,
                        fallback: widget.mimoPreset!,
                      ),
                      icon: const Icon(Icons.auto_fix_high_outlined),
                      label: const Text('切换到 MiMo TTS'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '不同服务商的地址、模型、API Key 和音色会分别保存。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: 'sk-...',
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示 API Key' : '隐藏 API Key',
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onChanged: _onApiKeyChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildAliyunModelPresets(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final model = widget.config.model.trim();
    final needsWorkspace =
        widget.config.isAliyunQwenAudioTtsModel ||
        widget.config.isAliyunCosyVoiceTtsModel;
    const presets = <(String, String, String)>[
      (MediaApiConfig.aliyunQwen3TtsModel, 'Qwen3 性价比', '指令音色 · ¥0.8/万字'),
      (
        MediaApiConfig.aliyunQwenAudioTtsModel,
        'Qwen-Audio 低延迟',
        '情绪/复刻 · ¥1/万字',
      ),
      (
        MediaApiConfig.aliyunCosyVoiceTtsModel,
        'CosyVoice 自定义',
        '设计/复刻 · ¥0.8/万字',
      ),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('百炼 TTS 模型', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in presets)
                ChoiceChip(
                  label: Text(preset.$2),
                  tooltip: '${preset.$1}\n${preset.$3}',
                  selected: model == preset.$1,
                  onSelected: (_) => _selectAliyunTtsModel(preset.$1),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            needsWorkspace
                ? widget.config.hasAliyunWorkspaceBaseUrl
                      ? '已使用百炼 Workspace 地址。'
                      : '该模型需要把 Base URL 换成 '
                            'https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1'
                : 'Qwen3 使用公共 DashScope Base URL，可直接填写百炼 API Key。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: needsWorkspace && !widget.config.hasAliyunWorkspaceBaseUrl
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// TTS voice picker: MiMo modes (builtin / design / clone) + OpenAI chips +
  /// free-form custom id, matching the official MiMo V2.5 TTS docs.
  Widget _buildVoiceSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMimo =
        widget.config.effectiveSpeechProtocol ==
        SpeechApiProtocol.mimoChatCompletions;
    final isAliyun =
        widget.config.effectiveSpeechProtocol ==
        SpeechApiProtocol.aliyunModelStudio;
    final mode = widget.config.mimoTtsMode;
    final selectedVoice = widget.config.voice.trim();
    final builtinOptions = isMimo
        ? MediaApiConfig.mimoBuiltinVoices
        : isAliyun
        ? widget.config.aliyunBuiltinVoices
        : MediaApiConfig.openAiBuiltinVoices;
    final isKnownBuiltin = builtinOptions.any((v) => v.id == selectedVoice);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('音色', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          isMimo
              ? '支持官方内置音色、文案设计音色，以及上传录音克隆你的声音。'
              : isAliyun
              ? widget.config.isAliyunCosyVoiceTtsModel
                    ? 'CosyVoice v3.5 没有系统音色，请填写百炼中创建的复刻/设计 Voice ID。'
                    : '选择当前百炼模型支持的系统音色，或填写复刻/基础 Voice ID。'
              : '选择 OpenAI 兼容预设音色，或填写服务商自定义 Voice ID。',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (isMimo) ...[
          const SizedBox(height: 12),
          SegmentedButton<MimoTtsMode>(
            showSelectedIcon: false,
            segments: [
              for (final value in MimoTtsMode.values)
                ButtonSegment<MimoTtsMode>(
                  value: value,
                  label: Text(value.label, overflow: TextOverflow.ellipsis),
                  tooltip: value.description,
                ),
            ],
            selected: {mode},
            onSelectionChanged: (values) {
              if (values.isNotEmpty) _selectMimoTtsMode(values.first);
            },
          ),
          const SizedBox(height: 8),
          Text(
            mode.description,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (!isMimo || mode == MimoTtsMode.builtin) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in builtinOptions)
                FilterChip(
                  label: Text(option.label),
                  tooltip: option.detail.isEmpty
                      ? option.id
                      : '${option.label}（${option.detail}）',
                  selected:
                      selectedVoice == option.id ||
                      (selectedVoice.isEmpty &&
                          option.id ==
                              (isMimo
                                  ? MediaApiConfig.mimoDefaultVoice
                                  : isAliyun
                                  ? widget.config.aliyunDefaultVoice
                                  : MediaApiConfig.openAiDefaultVoice)),
                  onSelected: (_) => _patch(voice: option.id),
                ),
              FilterChip(
                label: const Text('自定义 ID'),
                selected: !isKnownBuiltin,
                onSelected: (_) {
                  // Leave free-form mode: clear a preset/data-URI selection so
                  // the text field appears (empty = endpoint default).
                  if (isKnownBuiltin || selectedVoice.startsWith('data:')) {
                    _patch(voice: '');
                    _sync(_voice, '');
                  }
                },
              ),
            ],
          ),
          if (!isKnownBuiltin) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _voice,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '自定义 Voice ID',
                hintText: isMimo
                    ? '例如 冰糖、Chloe，或服务商自定义 ID'
                    : isAliyun
                    ? widget.config.isAliyunCosyVoiceTtsModel
                          ? '填写声音复刻/设计生成的 Voice ID'
                          : '例如 Cherry、longanhuan_v3.6 或复刻 ID'
                    : '例如 alloy、nova，以服务商为准',
                helperText: selectedVoice.isEmpty
                    ? isAliyun && widget.config.aliyunDefaultVoice.isEmpty
                          ? '当前模型必须填写 Voice ID'
                          : '将使用默认音色'
                    : null,
              ),
              onChanged: (value) => _patch(voice: value),
            ),
          ],
        ],
        if (isMimo && mode == MimoTtsMode.design) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _voiceDesignPrompt,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '音色描述（必填）',
              alignLabelWithHint: true,
              hintText: '例如：二十多岁年轻女性，声音清亮柔和，语速适中，像电台深夜主播。',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => _patch(voiceDesignPrompt: value),
          ),
        ],
        if (isMimo && mode == MimoTtsMode.clone) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.config.hasVoiceCloneSample ? '已导入用户音色样本' : '尚未导入音色样本',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  widget.config.hasVoiceCloneSample
                      ? _basename(widget.config.voiceClonePath)
                      : '支持 mp3 / wav，建议清晰人声、数秒至一分钟，不超过约 7 MB。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _pickingCloneSample
                          ? null
                          : _pickVoiceCloneSample,
                      icon: _pickingCloneSample
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload_file_outlined),
                      label: Text(
                        widget.config.hasVoiceCloneSample ? '重新上传' : '上传录音',
                      ),
                    ),
                    if (widget.config.hasVoiceCloneSample)
                      OutlinedButton.icon(
                        onPressed: _clearVoiceCloneSample,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('清除样本'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _voiceDesignPrompt,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '风格指令（可选）',
              alignLabelWithHint: true,
              hintText: '例如：温和、沉稳，适合连续阅读；或加入方言/情绪标签说明。',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => _patch(voiceDesignPrompt: value),
          ),
        ],
        if (isMimo && mode == MimoTtsMode.builtin) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _voiceDesignPrompt,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '风格 / 导演指令（可选）',
              alignLabelWithHint: true,
              hintText: '例如：轻快上扬、略快语速；或（温柔）式标签说明。',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => _patch(voiceDesignPrompt: value),
          ),
        ],
        if (isAliyun) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _voiceDesignPrompt,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: '风格 / 情绪指令（可选）',
              alignLabelWithHint: true,
              hintText: '例如：温柔亲切，像朋友聊天；语速稍慢，重点词轻微加重。',
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => _patch(voiceDesignPrompt: value),
          ),
        ],
      ],
    );
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? path : normalized.substring(index + 1);
  }
}

class AnimeVoicePackGrid extends StatelessWidget {
  const AnimeVoicePackGrid({
    super.key,
    required this.selectedId,
    required this.onSelect,
    required this.onClear,
  });

  final String selectedId;
  final Future<void> Function(CustomTtsVoicePack pack) onSelect;
  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final pack in kAnimeStyleVoicePacks)
              FilterChip(
                selected: selectedId == pack.id,
                label: Text(pack.name),
                tooltip: '${pack.tagline}\n点按套用到云端语音合成',
                onSelected: (_) => onSelect(pack),
              ),
            if (selectedId.isNotEmpty)
              ActionChip(
                avatar: Icon(
                  Icons.clear,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                label: const Text('清除套用'),
                onPressed: () => onClear(),
              ),
          ],
        ),
        if (selectedId.isNotEmpty) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final pack = customTtsVoicePackById(selectedId);
              if (pack == null) return const SizedBox.shrink();
              return Text(
                '当前：${pack.name} · ${pack.tagline}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.primary),
              );
            },
          ),
        ],
      ],
    );
  }
}

Future<ProviderPreset?> pickProviderPreset(BuildContext context) {
  return showDialog<ProviderPreset>(
    context: context,
    builder: (dialogContext) => const ProviderPresetPickerDialog(),
  );
}
