import 'dart:convert';
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
  Widget build(BuildContext context) =>
      widget.file.artifactManifest != null &&
          (widget.file.artifactManifest!['kind'] == 'directory' ||
              (widget.file.artifactManifest!['bytes'] as num? ?? 0) >
                  8 * 1024 * 1024)
      ? FutureBuilder<WorkToolSession>(
          future: _opening,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: SelectableText('${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.file.path,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text('最终成果清单；文件内容未载入。目录可在工作区文件页浏览，大文件请从原工作目录打开。'),
                  const SizedBox(height: 8),
                  SelectableText(
                    const JsonEncoder.withIndent(
                      '  ',
                    ).convert(widget.file.artifactManifest),
                  ),
                ],
              ),
            );
          },
        )
      : WorkspaceFileTab(
          path: widget.file.path,
          tabController: widget.tabController,
          onDirtyChanged: widget.onDirtyChanged,
          scope: widget.file.scope,
          session: _opening,
        );
}
