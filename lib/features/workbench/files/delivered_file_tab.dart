import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../domain/desktop/workspace_tools.dart';
import '../../../state/work_changes.dart';
import 'work_file_access.dart';
import 'workspace_file_tab.dart';

class DeliveredFileTab extends ConsumerStatefulWidget {
  const DeliveredFileTab({
    super.key,
    required this.file,
    this.tabController,
    this.onDirtyChanged,
  });
  final WorkFileChange file;
  final FileTabController? tabController;
  final ValueChanged<bool>? onDirtyChanged;
  @override
  ConsumerState<DeliveredFileTab> createState() => _DeliveredFileTabState();
}

class _DeliveredFileTabState extends ConsumerState<DeliveredFileTab> {
  final _token = CancelToken();
  WorkToolSession? _session;
  late final Future<WorkToolSession> _opening;
  @override
  void initState() {
    super.initState();
    _opening = openDeliverySession(ref, widget.file, _token);
    _opening.then((session) {
      if (mounted) {
        _session = session;
      } else {
        session.close();
      }
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    _token.cancel();
    _session?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkspaceFileTab(
    path: widget.file.path,
    tabController: widget.tabController,
    onDirtyChanged: widget.onDirtyChanged,
    scope: widget.file.scope,
    session: _opening,
  );
}
