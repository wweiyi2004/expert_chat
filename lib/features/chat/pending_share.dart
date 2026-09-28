import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/share/shared_intake.dart';

/// Content shared from another app, waiting for [ChatPage] to place it in the
/// composer of the freshly opened conversation. Never sent automatically.
final pendingSharedPayloadProvider =
    NotifierProvider<PendingSharedPayload, SharedPayload?>(
      PendingSharedPayload.new,
    );

class PendingSharedPayload extends Notifier<SharedPayload?> {
  @override
  SharedPayload? build() => null;

  void set(SharedPayload? payload) => state = payload;

  /// Returns the pending payload and clears it, so it is applied only once.
  SharedPayload? take() {
    final payload = state;
    state = null;
    return payload;
  }
}
