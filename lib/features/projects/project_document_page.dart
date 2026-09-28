import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../data/library_models.dart';
import '../../data/models.dart';
import '../../domain/tools/file_parser.dart';
import '../shared/recovery_notice.dart';

class ProjectDocumentPage extends ConsumerStatefulWidget {
  const ProjectDocumentPage({super.key, required this.item});
  final LibraryItem item;
  @override
  ConsumerState<ProjectDocumentPage> createState() =>
      _ProjectDocumentPageState();
}

class _ProjectDocumentPageState extends ConsumerState<ProjectDocumentPage> {
  late Future<Attachment> _document = _load();
  Future<Attachment> _load() async {
    final item = widget.item;
    if (item.sizeBytes > FileParser.maxFileBytes) {
      throw const FormatException('文件超过 15 MB，无法在此预览。');
    }
    final bytes = await ref.read(libraryRepositoryProvider).readBytes(item);
    if (bytes == null) throw const FormatException('原文件已丢失，请从素材库重新关联资料。');
    if (sha256.convert(bytes).toString() != item.sha256) {
      throw const FormatException('文件内容已变化，请重新导入后再使用。');
    }
    return ref
        .read(fileParserProvider)
        .parseAsync(
          name: item.name,
          mimeType: item.mimeType,
          sizeBytes: bytes.length,
          bytes: bytes,
        );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: FutureBuilder<Attachment>(
      future: _document,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: RecoveryNotice(
              error: snapshot.error!,
              title: '资料暂时无法预览',
              onRetry: () async {
                setState(() => _document = _load());
                await _document;
              },
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final doc = snapshot.data!;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text('资料预览', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text('以下为文件中可提取的文字。项目回答仍受上下文预算限制。'),
                if (doc.parseError != null) ...[
                  const SizedBox(height: 16),
                  RecoveryNotice(error: doc.parseError!, title: '部分内容无法读取'),
                ],
                if (doc.truncated)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('内容较长，预览已截断。'),
                  ),
                if (doc.text.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: doc.text));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制资料文字')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('复制文字'),
                    ),
                  ),
                const SizedBox(height: 16),
                SelectableText(
                  doc.text.isEmpty ? '没有可预览的文字。扫描件可能需要先进行文字识别。' : doc.text,
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
