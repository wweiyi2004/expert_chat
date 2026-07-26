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
  });

  final int originalTokens;
  final int sentTokens;
  final int inputBudgetTokens;
  final int droppedMessages;
  final bool truncated;

  bool get managed => droppedMessages > 0 || truncated;
  double get fraction =>
      inputBudgetTokens <= 0 ? 0 : sentTokens / inputBudgetTokens;
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
class ContextWindowManager {
  const ContextWindowManager();

  static const int _messageOverheadTokens = 6;
  static const int _imageEstimateTokens = 1200;

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
    final reversedUnits = units.reversed.toList();
    final boundedUnitsReversed = <List<LlmRequestMessage>>[];
    var boundedMessageCount = 0;
    var hasUserMessage = false;
    var index = 0;
    for (; index < reversedUnits.length; index++) {
      final unit = reversedUnits[index];
      if (boundedUnitsReversed.isNotEmpty &&
          boundedMessageCount + unit.length > prefs.maxHistoryMessages) {
        break;
      }
      boundedUnitsReversed.add(unit);
      boundedMessageCount += unit.length;
      hasUserMessage =
          hasUserMessage || unit.any((m) => m.role == MessageRole.user);
    }
    // In tool follow-up turns the newest units are tool-call protocol, so a
    // small cap can fill up before reaching the user question currently being
    // answered. That question must stay in the request even over the cap.
    if (!hasUserMessage) {
      for (; index < reversedUnits.length; index++) {
        final unit = reversedUnits[index];
        if (unit.any((m) => m.role == MessageRole.user)) {
          boundedUnitsReversed.add(unit);
          boundedMessageCount += unit.length;
          break;
        }
      }
    }
    final boundedUnits = boundedUnitsReversed.reversed.toList();
    var dropped = conversation.length - boundedMessageCount;
    var truncated = false;

    // Keep both the opening instructions and the latest injected context when
    // system material itself is too large.
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

    var remaining = budget - estimateMessagesTokens(managedSystem);
    final selectedUnitsReversed = <List<LlmRequestMessage>>[];
    for (var i = boundedUnits.length - 1; i >= 0; i--) {
      final unit = boundedUnits[i];
      final cost = estimateMessagesTokens(unit);
      if (cost <= remaining) {
        selectedUnitsReversed.add(unit);
        remaining -= cost;
        continue;
      }

      // The newest message is the user's current request. It must remain in the
      // request even if an enormous attachment consumed its budget; retain its
      // tail because the actual question is appended after attachment text.
      if (selectedUnitsReversed.isEmpty &&
          remaining > _messageOverheadTokens + 32) {
        final clipped = _clipUnit(unit, remaining);
        selectedUnitsReversed.add(clipped);
        truncated = true;
        remaining = 0;
      } else {
        dropped += boundedUnits
            .take(i + 1)
            .fold<int>(0, (sum, older) => sum + older.length);
        break;
      }
    }

    final managed = <LlmRequestMessage>[
      ...managedSystem,
      for (final unit in selectedUnitsReversed.reversed) ...unit,
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
      ),
    );
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
