import 'package:riverpod/riverpod.dart';
import 'dart:io';
import 'package:expert_chat/features/tui_bridge/backend.dart';

// Compile-only dependency check while extracting the shared desktop runtime.
void main() {
  final container = ProviderContainer();
  final backend = ControllerBridgeBackend(container);
  stdout.writeln('Shared runtime capabilities: ${backend.capabilities.length}');
  container.dispose();
}
