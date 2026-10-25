import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../domain/workbench/git/git_workspace.dart';

class GitCommitGraph extends StatelessWidget {
  const GitCommitGraph({
    super.key,
    required this.snapshot,
    required this.onSelect,
  });
  final GitWorkspaceSnapshot snapshot;
  final ValueChanged<GitCommit> onSelect;
  @override
  Widget build(BuildContext context) {
    final rows = <_GraphRow>[];
    var lanes = <String>[];
    var columns = 1;
    for (final commit in snapshot.commits) {
      final incoming = lanes.contains(commit.id);
      if (!incoming) lanes.add(commit.id);
      final before = List<String>.of(lanes), node = before.indexOf(commit.id);
      final after = List<String>.of(before)..removeAt(node);
      var insert = node;
      for (final parent in commit.parents) {
        if (!after.contains(parent)) {
          after.insert(math.min(insert, after.length), parent);
          insert++;
        }
      }
      rows.add(
        _GraphRow(
          commit,
          node,
          incoming,
          [
            for (var i = 0; i < before.length; i++)
              if (i != node) (i, after.indexOf(before[i])),
          ],
          [for (final parent in commit.parents) after.indexOf(parent)],
        ),
      );
      columns = math.max(columns, math.max(before.length, after.length));
      lanes = after;
    }
    final graphWidth = math.max(42.0, columns * 18.0 + 18);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: Row(
            children: [
              const Icon(Icons.account_tree_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  snapshot.branch.isEmpty ? 'Git 提交图' : snapshot.branch,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                '${rows.length} 次提交',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('仓库还没有提交'))
              : LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: math.max(constraints.maxWidth, graphWidth + 280),
                      child: ListView.builder(
                        itemCount: rows.length + 1,
                        itemBuilder: (context, index) {
                          if (index == rows.length) {
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                '显示各分支最近 120 次提交；底部连线可能延伸到更早的提交。',
                                style: TextStyle(fontSize: 11),
                              ),
                            );
                          }
                          final row = rows[index];
                          return InkWell(
                            onTap: () => onSelect(row.commit),
                            child: SizedBox(
                              height: 76,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: graphWidth,
                                    height: 76,
                                    child: CustomPaint(
                                      painter: _GraphPainter(
                                        row,
                                        Theme.of(context).colorScheme,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        6,
                                        8,
                                        14,
                                        8,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            row.commit.subject,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '${row.commit.id.substring(0, 7)} · ${row.commit.author} · ${row.commit.date}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.labelSmall,
                                          ),
                                          if (row.commit.refs.isNotEmpty)
                                            Text(
                                              row.commit.refs,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _GraphRow {
  const _GraphRow(
    this.commit,
    this.node,
    this.incoming,
    this.through,
    this.parents,
  );
  final GitCommit commit;
  final int node;
  final bool incoming;
  final List<(int, int)> through;
  final List<int> parents;
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.row, this.colors);
  final _GraphRow row;
  final ColorScheme colors;
  Color lane(int index) {
    final base = HSLColor.fromColor(colors.primary);
    return base
        .withHue((base.hue + index * 57) % 360)
        .withSaturation(.58)
        .toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    double x(int column) => 16 + column * 18.0;
    final y = size.height / 2;
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    for (final edge in row.through) {
      if (edge.$2 < 0) continue;
      pen.color = lane(edge.$1);
      canvas.drawPath(
        Path()
          ..moveTo(x(edge.$1), 0)
          ..cubicTo(x(edge.$1), y, x(edge.$2), y, x(edge.$2), size.height),
        pen,
      );
    }
    pen.color = lane(row.node);
    if (row.incoming) {
      canvas.drawLine(Offset(x(row.node), 0), Offset(x(row.node), y), pen);
    }
    for (final parent in row.parents) {
      canvas.drawPath(
        Path()
          ..moveTo(x(row.node), y)
          ..cubicTo(
            x(row.node),
            y + 20,
            x(parent),
            y + 20,
            x(parent),
            size.height,
          ),
        pen,
      );
    }
    canvas.drawCircle(
      Offset(x(row.node), y),
      row.commit.parents.length > 1 ? 5.5 : 4.5,
      Paint()..color = colors.surface,
    );
    canvas.drawCircle(
      Offset(x(row.node), y),
      row.commit.parents.length > 1 ? 5.5 : 4.5,
      pen,
    );
    canvas.drawCircle(
      Offset(x(row.node), y),
      2,
      Paint()..color = lane(row.node),
    );
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) =>
      old.row != row || old.colors != colors;
}
