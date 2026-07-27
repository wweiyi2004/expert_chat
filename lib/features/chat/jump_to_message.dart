import 'package:flutter_riverpod/flutter_riverpod.dart';

/// When non-null, [ChatPage] should scroll to this message id after opening
/// the conversation (set by history search “定位”).
final pendingJumpMessageIdProvider =
    NotifierProvider<PendingJumpMessageId, String?>(PendingJumpMessageId.new);

class PendingJumpMessageId extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? id) => state = id;

  void clear() => state = null;
}
