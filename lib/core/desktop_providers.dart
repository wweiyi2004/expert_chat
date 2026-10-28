import 'package:riverpod/riverpod.dart';
import '../domain/desktop/workspace_host.dart';
import '../domain/desktop/workspace_host_factory.dart';

final desktopWorkspaceHostProvider = Provider<DesktopWorkspaceHost>(
  (ref) => createDesktopWorkspaceHost(),
);

// Navigation lists registered projects without creating a default workspace.
final registeredDesktopWorkspacesProvider =
    FutureProvider.autoDispose<List<DesktopWorkspace>>((ref) {
      final host = ref.watch(desktopWorkspaceHostProvider);
      return host.supported ? host.list() : Future.value(const []);
    });

final desktopWorkspacesProvider =
    FutureProvider.autoDispose<List<DesktopWorkspace>>((ref) async {
      final host = ref.watch(desktopWorkspaceHostProvider);
      if (!host.supported) return const [];
      await host.defaultWorkspace();
      return host.list();
    });
