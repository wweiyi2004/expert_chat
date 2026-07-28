import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One-shot research-mode enable FX (rainbow ripple from the toggle).
class ResearchModeFxState {
  const ResearchModeFxState({
    this.playing = false,
    this.originGlobal,
  });

  final bool playing;

  /// Global (screen) coordinates of the research-mode switch center.
  final Offset? originGlobal;

  ResearchModeFxState copyWith({
    bool? playing,
    Object? originGlobal = _s,
  }) => ResearchModeFxState(
    playing: playing ?? this.playing,
    originGlobal: identical(originGlobal, _s)
        ? this.originGlobal
        : originGlobal as Offset?,
  );

  static const _s = Object();
}

final researchModeFxProvider =
    NotifierProvider<ResearchModeFxController, ResearchModeFxState>(
      ResearchModeFxController.new,
    );

class ResearchModeFxController extends Notifier<ResearchModeFxState> {
  @override
  ResearchModeFxState build() => const ResearchModeFxState();

  /// [originGlobal] should be the switch's center in global coordinates.
  void play({Offset? originGlobal}) {
    state = ResearchModeFxState(playing: true, originGlobal: originGlobal);
  }

  void finish() {
    if (!state.playing) return;
    state = const ResearchModeFxState();
  }
}
