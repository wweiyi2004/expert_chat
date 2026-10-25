import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'return_to_conversation.dart';
import 'shell_tab.dart';
import '../../state/conversation_attention.dart';
import '../../core/application_surface.dart';

const conversationSettingsRouteName = '/settings/from-conversation';

/// Observes the real root navigator, so nested settings editors share the bar.
class ConversationRouteObserver extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> _routes = [];
  bool _returning = false, _disposed = false;
  bool get rootVisible => _routes.length == 1 && pageVisible;
  int get pageDepth => _routes.whereType<PageRoute<dynamic>>().length;
  bool get pageVisible => _routes.isNotEmpty && _routes.last is PageRoute;
  bool get hasSettingsDestination => _routes.any(
    (route) => route.settings.name == conversationSettingsRouteName,
  );
  void _changed() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!_disposed) notifyListeners();
  });
  Future<bool> returnToRoot() async {
    if (_returning || _disposed) return false;
    if (!pageVisible) {
      // A menu's result can complete just before the observer sees its pop.
      await WidgetsBinding.instance.endOfFrame;
      if (!pageVisible || _disposed) return false;
    }
    _returning = true;
    try {
      final retriedRoutes = <Route<dynamic>>{};
      while (_routes.length > 1) {
        final count = _routes.length;
        final route = _routes.last;
        await navigator?.maybePop();
        // A PopScope may consume the request while saving or asking about
        // unsaved edits. Stop; never force-pop that route.
        if (_routes.length >= count) {
          if (!retriedRoutes.add(route)) return false;
          // Settings may first consume Back to return from its category to
          // overview. Continue only if that transition now explicitly allows
          // a pop; saving/unsaved-edit guards keep doNotPop and stop here.
          await WidgetsBinding.instance.endOfFrame;
          if (_disposed ||
              _routes.length != count ||
              !identical(_routes.last, route) ||
              route.popDisposition != RoutePopDisposition.pop) {
            return false;
          }
        }
      }
      if (navigator?.canPop() ?? false) {
        // Drawer and LocalHistoryEntry aren't separate observed routes.
        await navigator?.maybePop();
        return false;
      }
      return rootVisible;
    } finally {
      _returning = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) _routes[index] = newRoute;
    _changed();
  }
}

class ConversationReturnScope extends ConsumerWidget {
  const ConversationReturnScope({
    super.key,
    required this.navigatorKey,
    required this.observer,
    required this.child,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final ConversationRouteObserver observer;
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(shellTabProvider);
    ref.watch(conversationAttentionProvider);
    return ListenableBuilder(
      listenable: observer,
      child: child,
      builder: (context, child) {
        final destination =
            selected != ShellTab.chat || observer.hasSettingsDestination;
        final show =
            (destination || ApplicationSurface.hasActive) &&
            observer.pageVisible;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            ref
                .read(conversationRouteVisibleProvider.notifier)
                .set(observer.rootVisible);
          }
        });
        final wide = MediaQuery.sizeOf(context).width >= 840;
        Future<bool> back() async {
          if (wide && !await ApplicationSurface.closeActive()) return false;
          if (!await observer.returnToRoot() || !context.mounted) return false;
          ref.read(shellTabProvider.notifier).set(ShellTab.chat);
          return true;
        }

        return Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (!show ||
                event is! KeyDownEvent ||
                event.logicalKey != LogicalKeyboardKey.escape) {
              return KeyEventResult.ignored;
            }
            final focus = FocusManager.instance.primaryFocus;
            if (focus?.context?.widget is EditableText ||
                focus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
                    null) {
              return KeyEventResult.ignored;
            }
            back();
            return KeyEventResult.handled;
          },
          child: ConversationChromeOverlay(
            child: Column(
              children: [
                if (destination && wide && observer.pageDepth > 1)
                  Visibility(
                    visible: observer.pageVisible,
                    maintainState: true,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: ReturnToConversation(
                          compact: true,
                          onReturn: back,
                          navigatorKey: navigatorKey,
                        ),
                      ),
                    ),
                  ),
                Expanded(child: child!),
                if (destination && !wide)
                  Visibility(
                    visible: observer.pageVisible,
                    maintainState: true,
                    child: ReturnToConversation(
                      onReturn: back,
                      navigatorKey: navigatorKey,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Supplies a full viewport Overlay to chrome tooltips outside the root
/// Navigator. Menus explicitly use the root Navigator's overlay context.
class ConversationChromeOverlay extends StatefulWidget {
  const ConversationChromeOverlay({super.key, required this.child});
  final Widget child;
  @override
  State<ConversationChromeOverlay> createState() =>
      _ConversationChromeOverlayState();
}

class _ConversationChromeOverlayState extends State<ConversationChromeOverlay> {
  late final _entry = OverlayEntry(builder: (_) => widget.child);
  @override
  void didUpdateWidget(covariant ConversationChromeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _entry.remove();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}
