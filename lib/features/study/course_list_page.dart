import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mode_style.dart';
import '../../core/providers.dart';
import '../../data/study_models.dart';
import '../../domain/study/course_tree.dart';
import '../../domain/tools/file_parser.dart';
import '../../domain/tools/local_file_reader.dart';
import '../../state/study_controller.dart';
import 'course_detail_page.dart';
import 'study_ui.dart';

class CourseListPage extends ConsumerStatefulWidget {
  const CourseListPage({super.key});

  @override
  ConsumerState<CourseListPage> createState() => _CourseListPageState();
}

class _CourseListPageState extends ConsumerState<CourseListPage> {
  var _creating = false;

  Future<void> _deleteCourse(StudyCourse course) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除课程？'),
        content: Text('「${course.title}」的知识点和进度会一起删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(studyControllerProvider.notifier).deleteCourse(course.id);
  }

  Future<void> _newCourse() async {
    final draft = await showDialog<_CourseDraft>(
      context: context,
      builder: (_) => const _NewCourseDialog(),
    );
    if (draft == null || !mounted) return;
    setState(() => _creating = true);
    try {
      final course = await ref
          .read(studyControllerProvider.notifier)
          .createCourseFromTopic(draft.topic, material: draft.material);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CourseDetailPage(courseId: course.id),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('创建失败：$e')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(studyControllerProvider).value ?? StudyLibrary.empty;
    final courses = lib.courses;

    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: const Text('课程'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _creating ? null : _newCourse,
        icon: _creating
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_creating ? '生成中…' : '新建课程'),
      ),
      body: StudyContent(
        maxWidth: 860,
        bottomPadding: 96,
        children: [
          const StudyPageLead(
            icon: Icons.route_outlined,
            title: '按一条清晰的路径学习',
            subtitle: '从主题或资料生成课程，把大问题拆成可完成的知识点。',
          ),
          if (courses.isEmpty)
            StudyPanel(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(
                      Icons.account_tree_outlined,
                      size: 42,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '还没有课程',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '用一个主题或一份学习资料开始',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _creating ? null : _newCourse,
                      icon: const Icon(Icons.add),
                      label: const Text('创建第一门课程'),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            const StudySectionTitle(title: '我的课程', subtitle: '选择一门课程继续学习'),
            const SizedBox(height: 12),
            for (var i = 0; i < courses.length; i++) ...[
              _CourseRow(
                course: courses[i],
                nodes: lib.nodes
                    .where((node) => node.courseId == courses[i].id)
                    .toList(),
                onOpen: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CourseDetailPage(courseId: courses[i].id),
                  ),
                ),
                onDelete: () => _deleteCourse(courses[i]),
              ),
              if (i != courses.length - 1) const SizedBox(height: 9),
            ],
          ],
        ],
      ),
    );
  }
}

class _CourseRow extends StatelessWidget {
  const _CourseRow({
    required this.course,
    required this.nodes,
    required this.onOpen,
    required this.onDelete,
  });

  final StudyCourse course;
  final List<StudyNode> nodes;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ratio = const CourseTreeCodec().progressRatio(nodes);
    final leaves = nodes.where((node) => node.kind == StudyNodeKind.leaf);
    final done = leaves
        .where((node) => node.progress == StudyNodeProgress.done)
        .length;
    final total = leaves.length;
    return StudyPanel(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 15),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: ModeStyle.study.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.menu_book_outlined,
                  color: ModeStyle.study,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      course.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: ratio,
                              minHeight: 5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '$done / $total',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '课程操作',
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CourseDraft {
  const _CourseDraft({required this.topic, required this.material});

  final String topic;
  final String material;
}

class _NewCourseDialog extends ConsumerStatefulWidget {
  const _NewCourseDialog();

  @override
  ConsumerState<_NewCourseDialog> createState() => _NewCourseDialogState();
}

class _NewCourseDialogState extends ConsumerState<_NewCourseDialog> {
  static const _extensions = [
    'pdf',
    'docx',
    'xlsx',
    'pptx',
    'txt',
    'md',
    'csv',
    'tsv',
    'json',
  ];

  final _topic = TextEditingController();
  String _material = '';
  String? _fileName;
  String? _fileNote;
  var _picking = false;

  @override
  void dispose() {
    _topic.dispose();
    super.dispose();
  }

  Future<void> _pickMaterial() async {
    setState(() {
      _picking = true;
      _fileNote = null;
    });
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: false,
        withData: false,
        withReadStream: true,
        type: FileType.custom,
        allowedExtensions: _extensions,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      if (file.size > FileParser.maxFileBytes) {
        throw const FileReadLimitExceeded(FileParser.maxFileBytes);
      }
      final stream = file.readStream ?? openLocalFileReadStream(file.path);
      if (stream == null) throw StateError('无法读取该文件');
      final bytes = await FileParser.readBytesWithLimit(
        stream,
        maxBytes: FileParser.maxFileBytes,
      );
      final attachment = await ref
          .read(fileParserProvider)
          .parseAsync(
            name: file.name,
            mimeType: _mimeFor(file.extension),
            sizeBytes: bytes.lengthInBytes,
            bytes: bytes,
          );
      final text = attachment.text.trim();
      if (attachment.parseError != null ||
          text.isEmpty ||
          text.startsWith('（本地文本解析失败') ||
          text.startsWith('（未能从文件中提取到文本')) {
        throw FormatException(attachment.parseError ?? '未提取到可用文本');
      }
      if (!mounted) return;
      setState(() {
        _material = '[资料：${file.name}]\n$text';
        _fileName = file.name;
        _fileNote = attachment.truncated ? '文本较长，已截取前 60000 字' : null;
        if (_topic.text.trim().isEmpty) {
          _topic.text = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
        }
      });
    } on FileReadLimitExceeded {
      if (mounted) {
        setState(() => _fileNote = '文件超过 15 MB，无法导入');
      }
    } catch (error) {
      if (mounted) setState(() => _fileNote = '导入失败：$error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _submit() {
    final topic = _topic.text.trim();
    if (topic.isEmpty) {
      setState(() => _fileNote = '请填写课程主题');
      return;
    }
    Navigator.pop(context, _CourseDraft(topic: topic, material: _material));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建课程'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _topic,
              decoration: const InputDecoration(
                labelText: '主题',
                hintText: '例如：高中物理力学',
              ),
              autofocus: true,
              onSubmitted: (_) => _picking ? null : _submit(),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _picking ? null : _pickMaterial,
                  icon: _picking
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.attach_file),
                  label: Text(_picking ? '解析中…' : '导入学习资料'),
                ),
                if (_fileName != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _fileName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '移除资料',
                    onPressed: () => setState(() {
                      _material = '';
                      _fileName = null;
                      _fileNote = null;
                    }),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _fileNote ?? '可选：PDF、Word、Excel、PPT 或文本；扫描件暂不支持 OCR。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color:
                    _fileNote?.startsWith('导入失败') == true ||
                        _fileNote?.startsWith('文件超过') == true
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _picking ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _picking ? null : _submit,
          child: const Text('生成大纲'),
        ),
      ],
    );
  }

  String _mimeFor(String? extension) => switch (extension?.toLowerCase()) {
    'pdf' => 'application/pdf',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'csv' => 'text/csv',
    'tsv' => 'text/tab-separated-values',
    'json' => 'application/json',
    'md' => 'text/markdown',
    _ => 'text/plain',
  };
}
