import 'package:characters/characters.dart';

import '../../data/context_prefs.dart';
import '../../data/models.dart';
import '../llm/llm_provider.dart';

class ContextWindowReport {
  const ContextWindowReport({
    required this.originalTokens,
    required this.sentTokens,
    required this.inputBudgetTokens,
    this.droppedMessages = 0,
    this.truncated = false,
    this.summaryInjected = false,
  });

  final int originalTokens;
  final int sentTokens;
  final int inputBudgetTokens;
  final int droppedMessages;
  final bool truncated;

  /// True when an extractive rolling summary of dropped history was injected.
  final bool summaryInjected;

  bool get managed =>
      droppedMessages > 0 || truncated || summaryInjected;

  double get fraction =>
      inputBudgetTokens <= 0 ? 0 : sentTokens / inputBudgetTokens;

  /// Short Chinese note for tooltips / accessibility.
  String get userFacingNote {
    if (!managed) {
      return '上下文约 $sentTokens / $inputBudgetTokens tokens';
    }
    final parts = <String>[
      '上下文约 $sentTokens / $inputBudgetTokens tokens',
    ];
    if (droppedMessages > 0) {
      parts.add('省略较早 $droppedMessages 条');
    }
    if (summaryInjected) {
      parts.add('已生成历史摘要');
    }
    if (truncated) {
      parts.add('部分内容已裁剪');
    }
    return parts.join(' · ');
  }
}

class ContextWindowResult {
  const ContextWindowResult({required this.messages, required this.report});

  final List<LlmRequestMessage> messages;
  final ContextWindowReport report;
}

/// Provider-neutral context budgeting.
///
/// Exact tokenizers differ between model families, so requests use a
/// deliberately conservative estimate. Stored conversations are never changed;
/// only the transient request list is compacted.
///
/// When older turns are dropped, an **extractive rolling summary** is injected
/// as a system note so the model retains key facts without reloading full
/// history (chat-app oriented: free, local, no extra LLM call).
class ContextWindowManager {
  const ContextWindowManager();

  static const int _messageOverheadTokens = 6;
  static const int _imageEstimateTokens = 1200;

  /// Cap for the injected history summary (tokens, estimate).
  static const int maxSummaryTokens = 700;

  /// Soft per-line excerpt length in grapheme clusters.
  static const int _summaryLineGraphemes = 100;

  int estimateTextTokens(String text) {
    var asciiRun = 0;
    var nonAscii = 0;
    for (final rune in text.runes) {
      if (rune <= 0x7f) {
        asciiRun++;
      } else {
        nonAscii++;
      }
    }
    return ((asciiRun + 3) ~/ 4) + nonAscii;
  }

  int estimateMessageTokens(LlmRequestMessage message) =>
      _messageOverheadTokens +
      estimateTextTokens(message.content) +
      // Reasoning chains of thought are sent back verbatim on assistant turns;
      // omitting them systematically under-counts tool-loop requests.
      estimateTextTokens(message.reasoningContent ?? '') +
      message.imageDataUrls.length * _imageEstimateTokens +
      message.toolCalls.fold<int>(
        0,
        (sum, call) =>
            sum +
            estimateTextTokens(call.name ?? '') +
            estimateTextTokens(call.argumentsJson),
      );

  int estimateMessagesTokens(Iterable<LlmRequestMessage> messages) =>
      messages.fold<int>(0, (sum, m) => sum + estimateMessageTokens(m));

  int estimateStoredMessagesTokens(Iterable<ChatMessage> messages) {
    return messages.fold<int>(0, (sum, message) {
      final attachmentTokens = message.attachments.fold<int>(0, (total, a) {
        if (a.isImage && a.hasImageData) return total + _imageEstimateTokens;
        return total + estimateTextTokens(a.text);
      });
      return sum +
          _messageOverheadTokens +
          estimateTextTokens(message.content) +
          attachmentTokens;
    });
  }

  ContextWindowResult manage(
    List<LlmRequestMessage> messages,
    ContextPrefs prefs,
  ) {
    final originalTokens = estimateMessagesTokens(messages);
    final budget = prefs.inputBudgetTokens;
    if (!prefs.enabled) {
      return ContextWindowResult(
        messages: List.unmodifiable(messages),
        report: ContextWindowReport(
          originalTokens: originalTokens,
          sentTokens: originalTokens,
          inputBudgetTokens: budget,
        ),
      );
    }

    // Only the leading run of system messages is management-owned (persona,
    // instructions). System content injected mid-conversation — e.g. search
    // context deliberately placed right before the newest user turn — keeps
    // its position and competes for the budget like any other message.
    var leadingSystemEnd = 0;
    while (leadingSystemEnd < messages.length &&
        messages[leadingSystemEnd].role == MessageRole.system) {
      leadingSystemEnd++;
    }
    final system = messages.take(leadingSystemEnd).toList();
    final conversation = messages.skip(leadingSystemEnd).toList();
    final units = _groupProtocolUnits(conversation);

    // --- Phase 1: history-count bound (newest first) ---
    final selectedByCount = <int>[]; // indices into [units], newest first
    var boundedMessageCount = 0;
    var hasUserMessage = false;
    var index = units.length - 1;
    for (; index >= 0; index--) {
      final unit = units[index];
      if (selectedByCount.isNotEmpty &&
          boundedMessageCount + unit.length > prefs.maxHistoryMessages) {
        break;
      }
      selectedByCount.add(index);
      boundedMessageCount += unit.length;
      hasUserMessage =
          hasUserMessage || unit.any((m) => m.role == MessageRole.user);
    }
    // Tool follow-up: ensure a user question stays even if cap filled with tools.
    if (!hasUserMessage) {
      for (var j = index; j >= 0; j--) {
        if (units[j].any((m) => m.role == MessageRole.user)) {
          selectedByCount.add(j);
          boundedMessageCount += units[j].length;
          break;
        }
      }
    }

    // --- Phase 2: system packing ---
    var truncated = false;
    final systemText = system.map((m) => m.content).join('\n\n');
    final maxSystemTokens = (budget * 0.45).floor().clamp(256, budget);
    final managedSystemText = estimateTextTokens(systemText) > maxSystemTokens
        ? _clipMiddle(systemText, maxSystemTokens)
        : systemText;
    if (managedSystemText != systemText) truncated = true;
    final managedSystem = managedSystemText.trim().isEmpty
        ? const <LlmRequestMessage>[]
        : [
            LlmRequestMessage(
              role: MessageRole.system,
              content: managedSystemText,
            ),
          ];

    // --- Phase 3: token-pack selected units (newest first) ---
    var remaining = budget - estimateMessagesTokens(managedSystem);
    // Reserve a slice for optional summary so we don't fill 100% then fail inject.
    final summaryReserve = (remaining * 0.12).floor().clamp(0, maxSummaryTokens);
    var packRemaining = remaining - summaryReserve;

    final keptNewestFirst = <int>[];
    for (final unitIndex in selectedByCount) {
      final unit = units[unitIndex];
      final cost = estimateMessagesTokens(unit);
      if (cost <= packRemaining) {
        keptNewestFirst.add(unitIndex);
        packRemaining -= cost;
        continue;
      }
      // Newest unit must stay even if huge; clip it.
      if (keptNewestFirst.isEmpty &&
          packRemaining > _messageOverheadTokens + 32) {
        keptNewestFirst.add(unitIndex);
        truncated = true;
        packRemaining = 0;
        break;
      }
      break;
    }

    final keptSet = keptNewestFirst.toSet();
    final droppedUnits = <List<LlmRequestMessage>>[
      for (var i = 0; i < units.length; i++)
        if (!keptSet.contains(i)) units[i],
    ];
    var dropped = droppedUnits.fold<int>(0, (n, u) => n + u.length);

    // --- Phase 4: extractive rolling summary of dropped history ---
    var summaryInjected = false;
    LlmRequestMessage? summaryMessage;
    if (droppedUnits.isNotEmpty) {
      final summaryBudget = (summaryReserve + packRemaining)
          .clamp(48, maxSummaryTokens);
      final summaryText = _buildDroppedSummary(droppedUnits, summaryBudget);
      if (summaryText.isNotEmpty) {
        summaryMessage = LlmRequestMessage(
          role: MessageRole.system,
          content: summaryText,
        );
        final summaryCost = estimateMessageTokens(summaryMessage);
        // If summary still doesn't fit, clip further.
        if (summaryCost > summaryReserve + packRemaining) {
          final clipped = _clipStart(
            summaryText,
            (summaryReserve + packRemaining - _messageOverheadTokens)
                .clamp(32, maxSummaryTokens),
          );
          summaryMessage = LlmRequestMessage(
            role: MessageRole.system,
            content: clipped,
          );
        }
        summaryInjected = true;
      }
    }

    // Rebuild kept units oldest→newest; clip newest if needed.
    final keptOldestFirst = keptNewestFirst.reversed.toList();
    final packedConversation = <LlmRequestMessage>[];
    var usedAfterSystem = summaryInjected
        ? estimateMessageTokens(summaryMessage!)
        : 0;
    var room = budget - estimateMessagesTokens(managedSystem) - usedAfterSystem;

    for (var k = 0; k < keptOldestFirst.length; k++) {
      final unitIndex = keptOldestFirst[k];
      final unit = units[unitIndex];
      final isNewest = k == keptOldestFirst.length - 1;
      final cost = estimateMessagesTokens(unit);
      if (cost <= room) {
        packedConversation.addAll(unit);
        room -= cost;
        continue;
      }
      if (isNewest && room > _messageOverheadTokens + 32) {
        packedConversation.addAll(_clipUnit(unit, room));
        truncated = true;
        room = 0;
      }
      // Older units that no longer fit should not happen often (we packed
      // newest-first); if they do, count as dropped.
      if (!isNewest) {
        dropped += unit.length;
        // Remove from summary? Already summarized if was outside kept set.
      }
    }

    final managed = <LlmRequestMessage>[
      ...managedSystem,
      if (summaryMessage != null) summaryMessage,
      ...packedConversation,
    ];
    final sentTokens = estimateMessagesTokens(managed);
    return ContextWindowResult(
      messages: List.unmodifiable(managed),
      report: ContextWindowReport(
        originalTokens: originalTokens,
        sentTokens: sentTokens,
        inputBudgetTokens: budget,
        droppedMessages: dropped,
        truncated: truncated,
        summaryInjected: summaryInjected,
      ),
    );
  }

  /// Extractive multi-line summary of dropped protocol units (no LLM call).
  String _buildDroppedSummary(
    List<List<LlmRequestMessage>> droppedUnits,
    int tokenBudget,
  ) {
    if (droppedUnits.isEmpty || tokenBudget < 40) return '';

    final lines = <String>[
      '【历史摘要 · 系统自动生成】',
      '较早对话因上下文限制未完整发送。以下为摘录要点（非全文，仅供连贯）：',
    ];

    for (final unit in droppedUnits) {
      for (final m in unit) {
        final label = switch (m.role) {
          MessageRole.user => '用户',
          MessageRole.assistant => '助手',
          MessageRole.system => '系统',
          MessageRole.tool => '工具',
        };
        var text = m.content.trim().replaceAll(RegExp(r'\s+'), ' ');
        if (text.isEmpty && m.toolCalls.isNotEmpty) {
          final names = [
            for (final c in m.toolCalls)
              if ((c.name ?? '').isNotEmpty) c.name!,
          ];
          text = names.isEmpty ? '（工具调用）' : '（调用工具：${names.join('、')}）';
        }
        if (text.isEmpty) continue;
        // Skip very long raw tool dumps — keep a short head only.
        if (m.role == MessageRole.tool && text.characters.length > 80) {
          text = '${text.characters.take(80)}…';
        } else if (text.characters.length > _summaryLineGraphemes) {
          text = '${text.characters.take(_summaryLineGraphemes)}…';
        }
        lines.add('- $label：$text');
      }
    }

    if (lines.length <= 2) return '';

    var joined = lines.join('\n');
    if (estimateTextTokens(joined) > tokenBudget) {
      joined = _clipStart(joined, tokenBudget);
    }
    return joined;
  }

  List<List<LlmRequestMessage>> _groupProtocolUnits(
    List<LlmRequestMessage> messages,
  ) {
    final units = <List<LlmRequestMessage>>[];
    var i = 0;
    while (i < messages.length) {
      final message = messages[i];
      if (message.role == MessageRole.assistant &&
          message.toolCalls.isNotEmpty) {
        final unit = <LlmRequestMessage>[message];
        i++;
        while (i < messages.length && messages[i].role == MessageRole.tool) {
          unit.add(messages[i]);
          i++;
        }
        units.add(unit);
      } else {
        units.add([message]);
        i++;
      }
    }
    return units;
  }

  List<LlmRequestMessage> _clipUnit(
    List<LlmRequestMessage> unit,
    int tokenBudget,
  ) {
    if (unit.length == 1) {
      final message = unit.single;
      return [
        _clipMessage(
          message,
          tokenBudget - _messageOverheadTokens,
          keepEnd: message.role == MessageRole.user,
        ),
      ];
    }

    // Assistant tool call + its tool responses form one protocol unit and must
    // never be split. Share the available text budget while retaining all call
    // ids and tool-call metadata.
    final overhead = unit.length * _messageOverheadTokens;
    final perMessage = ((tokenBudget - overhead) ~/ unit.length).clamp(
      1,
      tokenBudget,
    );
    return [
      for (final message in unit)
        _clipMessage(
          message,
          perMessage,
          keepEnd: message.role == MessageRole.tool,
        ),
    ];
  }

  LlmRequestMessage _clipMessage(
    LlmRequestMessage message,
    int tokenBudget, {
    required bool keepEnd,
  }) {
    final fixedTokens =
        // Reasoning is preserved unclipped by [LlmRequestMessage], so its
        // estimated cost must come out of the clippable text budget.
        estimateTextTokens(message.reasoningContent ?? '') +
        message.imageDataUrls.length * _imageEstimateTokens +
        message.toolCalls.fold<int>(
          0,
          (sum, call) =>
              sum +
              estimateTextTokens(call.name ?? '') +
              estimateTextTokens(call.argumentsJson),
        );
    final textBudget = (tokenBudget - fixedTokens).clamp(1, tokenBudget);
    final clipped = keepEnd
        ? _clipEnd(message.content, textBudget)
        : _clipStart(message.content, textBudget);
    return LlmRequestMessage(
      role: message.role,
      content: clipped,
      reasoningContent: message.reasoningContent,
      toolCallId: message.toolCallId,
      toolCalls: message.toolCalls,
      imageDataUrls: message.imageDataUrls,
    );
  }

  String _clipStart(String text, int tokenBudget) {
    if (estimateTextTokens(text) <= tokenBudget) return text;
    const marker = '\n\n[后续内容已因上下文限制裁剪]';
    final available = (tokenBudget - estimateTextTokens(marker)).clamp(
      1,
      tokenBudget,
    );
    return '${_takeWithin(text, available, fromEnd: false)}$marker';
  }

  String _clipEnd(String text, int tokenBudget) {
    if (estimateTextTokens(text) <= tokenBudget) return text;
    const marker = '[较早内容已因上下文限制裁剪]\n\n';
    final available = (tokenBudget - estimateTextTokens(marker)).clamp(
      1,
      tokenBudget,
    );
    return '$marker${_takeWithin(text, available, fromEnd: true)}';
  }

  String _clipMiddle(String text, int tokenBudget) {
    if (estimateTextTokens(text) <= tokenBudget) return text;
    const marker = '\n\n[部分系统上下文已裁剪]\n\n';
    final available = (tokenBudget - estimateTextTokens(marker)).clamp(
      2,
      tokenBudget,
    );
    final headBudget = (available * 0.65).floor();
    final tailBudget = available - headBudget;
    return '${_takeWithin(text, headBudget, fromEnd: false)}'
        '$marker'
        '${_takeWithin(text, tailBudget, fromEnd: true)}';
  }

  String _takeWithin(String text, int tokenBudget, {required bool fromEnd}) {
    final graphemes = text.characters.toList(growable: false);
    var low = 0;
    var high = graphemes.length;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      final slice = fromEnd
          ? graphemes.sublist(graphemes.length - mid).join()
          : graphemes.sublist(0, mid).join();
      if (estimateTextTokens(slice) <= tokenBudget) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return fromEnd
        ? graphemes.sublist(graphemes.length - low).join()
        : graphemes.sublist(0, low).join();
  }
}
