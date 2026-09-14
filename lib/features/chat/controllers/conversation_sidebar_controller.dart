import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/conversation_repository.dart';
import '../../../data/models.dart';
import '../../../data/story_models.dart';

/// Debounced archive search and mode filtering, independent of page layout.
class ConversationSidebarController extends ChangeNotifier {
  ConversationSidebarController({
    required this.search,
    this.debounce = const Duration(milliseconds: 250),
  });

  final Future<List<SearchHit>> Function(String) search;
  final Duration debounce;
  String _query = '';
  List<SearchHit> _hits = const [];
  Set<String> _matchingIds = const {};
  ConversationMode? _mode;
  String? _error;
  bool _searching = false;
  bool _disposed = false;
  int _revision = 0;
  Timer? _timer;

  String get query => _query;
  List<SearchHit> get hits => _hits;
  ConversationMode? get mode => _mode;
  bool get searching => _searching;
  String? get error => _error;

  void setQuery(String value) {
    final query = value.trim();
    if (_disposed || query == _query) return;
    _query = query;
    _schedule();
  }

  void retry() {
    if (!_disposed && _query.isNotEmpty) _schedule(immediate: true);
  }

  void _schedule({bool immediate = false}) {
    _timer?.cancel();
    final revision = ++_revision;
    _hits = const [];
    _matchingIds = const {};
    _error = null;
    _searching = _query.isNotEmpty;
    notifyListeners();
    if (!_searching) return;
    final query = _query;
    _timer = Timer(
      immediate ? Duration.zero : debounce,
      () => unawaited(_run(query, revision)),
    );
  }

  Future<void> _run(String query, int revision) async {
    try {
      final hits = await search(query);
      if (_disposed || revision != _revision) return;
      _hits = List.unmodifiable(hits);
      _matchingIds = hits.map((hit) => hit.convoId).toSet();
    } catch (_) {
      if (_disposed || revision != _revision) return;
      _error = '搜索失败，请重试。';
    }
    if (_disposed || revision != _revision) return;
    _searching = false;
    notifyListeners();
  }

  void setMode(ConversationMode? value) {
    if (_disposed || value == _mode) return;
    _mode = value;
    notifyListeners();
  }

  bool matches(Conversation conversation) =>
      (_mode == null || _mode == conversation.mode) &&
      (_query.isEmpty || _matchingIds.contains(conversation.id));

  @override
  void dispose() {
    _disposed = true;
    ++_revision;
    _timer?.cancel();
    super.dispose();
  }
}
