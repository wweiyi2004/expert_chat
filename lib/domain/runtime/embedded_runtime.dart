import 'dart:async';
import 'package:riverpod/riverpod.dart';
import '../../core/providers.dart';
import '../../data/atomic_windows_preferences.dart';
import '../../data/backup_journal.dart';
import '../../data/db/app_database.dart';
import '../../data/drift_conversation_repository.dart';
import '../../data/full_backup_service.dart';
import '../../data/legacy_conversation_migration.dart';
import '../../data/library_file_store.dart';
import '../../data/memory_file_store.dart';
import '../../data/study_repository.dart';
import '../../platform/preferences.dart';
import '../../state/chat_controller.dart';

/// Mobile hosts the shared task services in its app process. Pages borrow this
/// container; navigating or rebuilding the shell never creates another engine.
class EmbeddedRuntime {
  EmbeddedRuntime(this.container, {this.closeStorage});

  final ProviderContainer container;
  final Future<void> Function()? closeStorage;
  Future<void>? _closing;
  bool get closed => _closing != null;

  static Future<EmbeddedRuntime> open() async {
    await installAtomicWindowsPreferences();
    final prefsFuture = SharedPreferences.getInstance();
    final database = AppDatabase();
    ProviderContainer? container;
    try {
      final prefs = await prefsFuture;
      await FullBackupService(
        database,
        LibraryFileStore(),
        MemoryFileStore(prefs),
        prefs,
        BackupJournal(),
      ).recoverPending();
      await Future.wait([
        migrateLegacyJsonToDrift(DriftConversationRepository(database)),
        StudyRepository(database, prefs).ensureMigrated(),
      ]);
      container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(database),
        ],
      );
      return EmbeddedRuntime(container, closeStorage: database.close);
    } catch (_) {
      container?.dispose();
      await database.close();
      rethrow;
    }
  }

  void reportBackground(bool background) {
    if (closed) return;
    final chat = container.read(chatControllerProvider);
    if (chat.hasValue) {
      container
          .read(chatControllerProvider.notifier)
          .reportAppBackground(background);
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      final chat = container.read(chatControllerProvider);
      if (chat.hasValue) {
        final controller = container.read(chatControllerProvider.notifier);
        await controller.stopAllLocalTasks();
        await controller.flushHostState();
      }
    } finally {
      container.dispose();
      await closeStorage?.call();
    }
  }
}
