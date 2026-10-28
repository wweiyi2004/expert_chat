import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';

class ControlledBrowserObservation {
  const ControlledBrowserObservation({
    required this.conversation,
    required this.server,
    required this.agent,
    required this.tool,
    required this.at,
    required this.text,
    this.image,
  });
  final String conversation, server, agent, tool, text;
  final DateTime at;
  final String? image;
  String get key => '$conversation:$server:$agent';
}

class ControlledBrowserState {
  const ControlledBrowserState({
    this.observations = const {},
    this.takeovers = const {},
    this.feedback = const {},
  });
  final Map<String, ControlledBrowserObservation> observations;
  final Set<String> takeovers;
  final Map<String, List<String>> feedback;
}

final controlledBrowserProvider =
    NotifierProvider<ControlledBrowserController, ControlledBrowserState>(
      ControlledBrowserController.new,
    );

class ControlledBrowserController extends Notifier<ControlledBrowserState> {
  @override
  ControlledBrowserState build() => const ControlledBrowserState();
  void observe({
    required String conversation,
    required String server,
    required String agent,
    required String tool,
    required String text,
    String? image,
  }) {
    if (image != null && image.length > 8 * 1024 * 1024) image = null;
    if (image != null) {
      try {
        base64Decode(image);
      } catch (_) {
        image = null;
      }
    }
    final item = ControlledBrowserObservation(
      conversation: conversation,
      server: server,
      agent: agent,
      tool: tool,
      at: DateTime.now(),
      text: text.length > 24000 ? text.substring(0, 24000) : text,
      image: image,
    );
    final observations = {...state.observations, item.key: item};
    while (observations.length > 12) {
      observations.remove(observations.keys.first);
    }
    state = ControlledBrowserState(
      observations: observations,
      takeovers: state.takeovers,
      feedback: state.feedback,
    );
  }

  bool takenOver(String conversation) => state.takeovers.contains(conversation);
  void takeover(String conversation, bool enabled) {
    ref.read(mcpClientProvider).setBrowserModelPaused(conversation, enabled);
    state = ControlledBrowserState(
      observations: state.observations,
      feedback: state.feedback,
      takeovers: {...state.takeovers}
        ..removeWhere((id) => id == conversation)
        ..addAll(enabled ? [conversation] : []),
    );
  }

  void addFeedback(String conversation, String text) {
    if (text.trim().isEmpty) return;
    final entries = [
      ...?state.feedback[conversation],
      text.length > 2000 ? text.substring(0, 2000) : text,
    ];
    state = ControlledBrowserState(
      observations: state.observations,
      takeovers: state.takeovers,
      feedback: {
        ...state.feedback,
        conversation: entries.reversed.take(10).toList().reversed.toList(),
      },
    );
  }

  List<String> consumeFeedback(String conversation) {
    final entries = state.feedback[conversation] ?? [];
    final next = {...state.feedback}..remove(conversation);
    state = ControlledBrowserState(
      observations: state.observations,
      takeovers: state.takeovers,
      feedback: next,
    );
    return entries;
  }

  void clear(String conversation) {
    ref.read(mcpClientProvider).setBrowserModelPaused(conversation, false);
    state = ControlledBrowserState(
      observations: {
        for (final entry in state.observations.entries)
          if (entry.value.conversation != conversation) entry.key: entry.value,
      },
      takeovers: {...state.takeovers}..remove(conversation),
      feedback: {...state.feedback}..remove(conversation),
    );
  }
}
