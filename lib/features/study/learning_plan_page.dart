import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import '../../core/providers.dart';
import '../../data/learning_plan.dart';
import '../../domain/tools/attachment_ingestor.dart';
import '../../state/learning_plan_controller.dart';

class LearningPlanPage extends ConsumerStatefulWidget {
  const LearningPlanPage({super.key, this.planId});
  final String? planId;
  @override
  ConsumerState<LearningPlanPage> createState() => _LearningPlanPageState();
}

class _LearningPlanPageState extends ConsumerState<LearningPlanPage> {
  final _topic = TextEditingController();
  final _goal = TextEditingController();
  final _material = TextEditingController();
  final _minutes = TextEditingController(text: '60');
  final _answer = TextEditingController();
  final _form = GlobalKey<FormState>();
  DateTime _deadline = DateTime.now().add(const Duration(days: 30));
  bool _foundation = true;
  bool _importing = false;
  String? _id, _day, _error;
  int _section = 0;
  @override
  void initState() {
    super.initState();
    _id = widget.planId;
  }

  @override
  void dispose() {
    for (final c in [_topic, _goal, _material, _minutes, _answer]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'docx', 'txt', 'md'],
        allowMultiple: true,
        withData: kIsWeb,
      );
      if (result == null || !mounted) return;
      final prepared =
          await AttachmentIngestor(parser: ref.read(fileParserProvider)).ingest(
            [
              for (final f in result.files)
                FileIngestSource(
                  name: f.name,
                  extension: f.extension,
                  path: f.path,
                  bytes: f.bytes,
                  reportedSize: f.size,
                ),
            ],
            slots: 8,
            existingBytes: 0,
            isCurrent: () => mounted,
          );
      if (!mounted) return;
      final text = prepared.attachments
          .map((a) => '[资料：${a.name}]\n${a.text}')
          .join('\n\n');
      _material.text = '${_material.text}\n$text'.trim();
      if (prepared.unreadable > 0 ||
          prepared.tooLarge > 0 ||
          prepared.tooMany > 0) {
        setState(() => _error = '部分文件未能导入，请检查文件大小、数量和可读文本。');
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _create() => _action(() async {
    if (!_form.currentState!.validate()) return;
    final id = await ref
        .read(learningPlanControllerProvider.notifier)
        .create(
          topic: _topic.text.trim(),
          goal: _goal.text.trim(),
          deadline: _deadline.toIso8601String().substring(0, 10),
          dailyMinutes: int.parse(_minutes.text),
          foundation: _foundation,
          material: _material.text.trim(),
        );
    if (mounted) setState(() => _id = id);
  });
  Future<void> _export(LearningPlan p) => _action(() async {
    final buffer = StringBuffer('# ${p.topic}\n\n目标：${p.goal}\n\n')
      ..writeln('## 知识清单\n');
    for (final k in p.knowledge) {
      buffer.writeln(
        '### ${k.id} · ${k.title}\n验收：${k.criterion}\n\n来源：${k.source}\n',
      );
    }
    buffer.writeln('## 备考计划\n\n${p.schedule}\n');
    for (final l in p.lessons) {
      buffer.writeln('## 每日课程 · ${l.date}\n\n${l.content}\n');
      for (final f in l.feedback) {
        buffer.writeln(
          '### 实际作答 · ${f.date}\n\n${f.answer}\n\n### 反馈\n\n${f.assessment}\n',
        );
      }
    }
    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final path = await FilePicker.saveFile(
      dialogTitle: '导出学习档案',
      fileName: 'learning-${p.id}.md',
      type: FileType.custom,
      allowedExtensions: ['md'],
      bytes: kIsWeb || mobile ? bytes : null,
    );
    if (!kIsWeb && !mobile && path != null) {
      await File(path).writeAsBytes(bytes);
    }
    if (mounted && (kIsWeb || path != null)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('学习档案已导出')));
    }
  });
  @override
  Widget build(BuildContext context) {
    final plans = ref.watch(learningPlanControllerProvider);
    final plan = plans.where((p) => p.id == _id).firstOrNull;
    final busy = ref.watch(learningBusyProvider).contains(_id ?? 'new');
    return Scaffold(
      appBar: AppBar(
        title: Text(plan?.topic ?? '建立学习计划'),
        actions: [
          if (plan != null)
            IconButton(
              tooltip: '导出学习档案',
              onPressed: () => _export(plan),
              icon: const Icon(Icons.ios_share_outlined),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_error != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!),
                  ),
                ),
              if (busy) const LinearProgressIndicator(),
              if (plan == null)
                _setup(busy)
              else ...[
                Text(
                  '目标：${plan.goal}  ·  每天 ${plan.dailyMinutes} 分钟  ·  截止 ${plan.deadline}',
                ),
                const SizedBox(height: 16),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('知识清单')),
                    ButtonSegment(value: 1, label: Text('备考计划')),
                    ButtonSegment(value: 2, label: Text('每日学习')),
                  ],
                  selected: {_section},
                  onSelectionChanged: (v) => setState(() => _section = v.first),
                ),
                const SizedBox(height: 20),
                if (_section == 0)
                  for (final k in plan.knowledge)
                    Card(
                      child: ListTile(
                        title: Text('${k.id} · ${k.title}'),
                        subtitle: Text(
                          '验收：${k.criterion}\n来源：${k.source}\n'
                          '状态：${plan.evidence[k.id] == true
                              ? '作答已验证（AI 评估）'
                              : plan.evidence[k.id] == false
                              ? '需要复习'
                              : '待作答验证'}',
                        ),
                        isThreeLine: true,
                      ),
                    ),
                if (_section == 1) ...[
                  GptMarkdown(plan.schedule),
                  if (plan.evidence.containsValue(false)) ...[
                    const Divider(),
                    const Text('调整依据：实际作答中存在需复习的知识点，下一次课程优先复习这些内容；历史课程和反馈会保留。'),
                  ],
                ],
                if (_section == 2) ...[
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => _action(() async {
                            await ref
                                .read(learningPlanControllerProvider.notifier)
                                .startToday(plan.id);
                            if (mounted) {
                              setState(
                                () => _day = DateTime.now()
                                    .toIso8601String()
                                    .substring(0, 10),
                              );
                            }
                          }),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(busy ? '正在准备…' : '开始今天的学习'),
                  ),
                  const SizedBox(height: 12),
                  if (plan.lessons.isEmpty)
                    const Text('点击开始后生成今日课程；未提交作答时保持“待验证”。'),
                  if (plan.lessons.isNotEmpty) ..._lesson(plan, busy),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _setup(bool busy) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('先确定目标与时间，再生成知识清单和备考计划。课程会在你点击开始时逐日建立。'),
        const SizedBox(height: 20),
        TextFormField(
          controller: _topic,
          decoration: const InputDecoration(labelText: '科目 / 考试 / 比赛'),
          validator: (v) => v == null || v.trim().isEmpty ? '请输入学习主题' : null,
        ),
        const SizedBox(height: 14),
        TextFormField(
          controller: _goal,
          decoration: const InputDecoration(labelText: '目标与当前水平'),
          validator: (v) => v == null || v.trim().isEmpty ? '请描述目标' : null,
        ),
        const SizedBox(height: 14),
        TextFormField(
          controller: _minutes,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '每天可用时间（分钟）'),
          validator: (v) {
            final n = int.tryParse(v ?? '');
            return n == null || n < 5 || n > 480 ? '请输入 5～480 分钟' : null;
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('截止日期'),
          subtitle: Text(_deadline.toIso8601String().substring(0, 10)),
          trailing: const Icon(Icons.calendar_month_outlined),
          onTap: () async {
            final now = DateTime.now();
            final date = await showDatePicker(
              context: context,
              initialDate: _deadline,
              firstDate: DateTime(now.year, now.month, now.day),
              lastDate: now.add(const Duration(days: 3650)),
            );
            if (date != null && mounted) setState(() => _deadline = date);
          },
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('零基础')),
            ButtonSegment(value: false, label: Text('复习')),
          ],
          selected: {_foundation},
          onSelectionChanged: (v) => setState(() => _foundation = v.first),
        ),
        const SizedBox(height: 18),
        TextFormField(
          controller: _material,
          minLines: 4,
          maxLines: 10,
          maxLength: 24000,
          decoration: const InputDecoration(
            labelText: '教材、考纲、试题与来源说明',
            hintText: '粘贴材料，或导入文件；没有材料时将标为待核对',
          ),
          validator: (v) =>
              (v?.length ?? 0) > 24000 ? '材料超过 24000 字，请保留相关章节' : null,
        ),
        TextButton.icon(
          onPressed: _importing || busy ? null : () => _action(_import),
          icon: const Icon(Icons.attach_file),
          label: Text(_importing ? '正在解析…' : '导入参考材料'),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: busy ? null : _create,
          child: Text(busy ? '正在生成清单与计划…' : '生成知识清单和备考计划'),
        ),
      ],
    ),
  );
  List<Widget> _lesson(LearningPlan p, bool busy) {
    final lesson =
        p.lessons.where((l) => l.date == _day).firstOrNull ?? p.lessons.last;
    return [
      DropdownButtonFormField<String>(
        key: ValueKey(lesson.date),
        initialValue: lesson.date,
        decoration: const InputDecoration(labelText: '学习记录'),
        items: [
          for (final l in p.lessons)
            DropdownMenuItem(value: l.date, child: Text(l.date)),
        ],
        onChanged: (v) => setState(() {
          _day = v;
          _answer.clear();
        }),
      ),
      const SizedBox(height: 20),
      GptMarkdown(lesson.content),
      const Divider(height: 32),
      for (final f in lesson.feedback)
        ExpansionTile(
          title: Text('作答反馈 · ${f.date.substring(0, 16)}'),
          children: [SelectableText(f.answer), GptMarkdown(f.assessment)],
        ),
      TextField(
        controller: _answer,
        minLines: 4,
        maxLines: 10,
        decoration: const InputDecoration(
          labelText: '提交实际作答 / 复做答案',
          hintText: '注明题号；系统会保留原始答案与订正反馈',
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.tonal(
        onPressed: busy
            ? null
            : () => _action(() async {
                await ref
                    .read(learningPlanControllerProvider.notifier)
                    .submit(p.id, lesson.date, _answer.text);
                if (mounted) _answer.clear();
              }),
        child: const Text('评估作答并调整后续学习'),
      ),
    ];
  }
}
