import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/research/research_safe_save.dart';

void main() {
  test(
    'private channel disables posix overwrite and refuses immutable unsupported negotiation',
    () {
      final extensions = {'posix-rename@openssh.com': '1', 'other': '1'};
      disableClobberingSftpRename(extensions);
      expect(extensions, {'other': '1'});
      expect(
        () => disableClobberingSftpRename(
          Map.unmodifiable({'posix-rename@openssh.com': '1'}),
        ),
        throwsStateError,
      );
      disableClobberingSftpRename(const {});
    },
  );
  for (final race in ['none', 'before_move', 'before_publish', 'late_inode']) {
    test('no-clobber recovery preserves editor data: $race', () async {
      final originalInode = <String>['original'];
      final files = <String, List<String>>{
        'target': originalInode,
        'temp': ['proposed'],
      };
      Future<void> rename(String source, String destination) async {
        if (race == 'before_move' && source == 'target') {
          files['target'] = ['editor'];
        }
        if (race == 'before_publish' && source == 'temp') {
          files['target'] = ['editor'];
        }
        if (files.containsKey(destination)) {
          throw StateError('destination exists');
        }
        files[destination] = files.remove(source)!;
      }

      final operation = publishSftpRecovery(
        path: 'target',
        staged: 'temp',
        recovery: 'backup',
        original: 'original',
        read: (path) async => files[path]!.single,
        rename: rename,
      );
      if (race == 'before_move' || race == 'before_publish') {
        await expectLater(operation, throwsStateError);
        expect(files['target']!.single, 'editor');
        expect(files.values.any((v) => v.single == 'proposed'), isTrue);
      } else {
        expect(await operation, 'backup');
        expect(files['target']!.single, 'proposed');
        if (race == 'late_inode') originalInode[0] = 'late editor write';
        expect(
          files['backup']!.single,
          race == 'late_inode' ? 'late editor write' : 'original',
        );
      }
    });
  }
}
