import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/update/update_sources.dart';

class UpdateSourcesPage extends StatefulWidget {
  const UpdateSourcesPage({super.key});
  @override
  State<UpdateSourcesPage> createState() => _UpdateSourcesPageState();
}

class _UpdateSourcesPageState extends State<UpdateSourcesPage> {
  List<UpdateSource> _sources = [];
  SharedPreferences? _prefs;
  String? _preferred;
  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(() {
          _prefs = p;
          _sources = UpdateSources.read(p);
          _preferred = p.getString(UpdateSources.preferredKey);
        });
      }
    });
  }

  Future<void> _edit([int? index]) async {
    final name = TextEditingController(
      text: index == null ? '' : _sources[index].name,
    );
    final url = TextEditingController(
      text: index == null ? '' : _sources[index].template,
    );
    final form = GlobalKey<FormState>();
    final result = await showDialog<UpdateSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载源'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '名称，例如 Gitee'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '请输入名称' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: url,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '安装包地址模板',
                    helperText: '版本：{tag}  文件名：{file}\n代理原始地址：{url}',
                  ),
                  validator: (v) => UpdateSource.validate(v?.trim() ?? ''),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Gitee 示例：https://gitee.com/所有者/仓库/releases/download/{tag}/{file}\n请先在对应仓库发布同版本安装包。',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(
                  ctx,
                  UpdateSource(
                    name: name.text.trim(),
                    template: url.text.trim(),
                  ),
                );
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // Dialog route transitions may still paint the fields after completion.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    url.dispose();
    if (result == null || !mounted) return;
    final next = [..._sources];
    if (index == null) {
      next.add(result);
    } else {
      next[index] = result;
    }
    await UpdateSources.save(_prefs!, next);
    if (mounted) setState(() => _sources = next);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('更新下载源')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: IconButton(
            tooltip: '首选 GitHub',
            onPressed: _prefs == null
                ? null
                : () async {
                    await _prefs!.remove(UpdateSources.preferredKey);
                    if (mounted) setState(() => _preferred = null);
                  },
            icon: Icon(
              _preferred == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
          ),
          title: const Text('GitHub Releases'),
          subtitle: const Text('默认源。中断后保留进度，再次下载会自动续传。'),
        ),
        const Text('下列备用源按顺序自动切换；没有文件校验值时，跨源切换会重新下载，避免混合不同文件。'),
        const SizedBox(height: 16),
        for (var i = 0; i < _sources.length; i++)
          Card(
            child: ListTile(
              leading: IconButton(
                tooltip: '设为首选下载源',
                onPressed: () async {
                  final value = _sources[i].template;
                  await _prefs!.setString(UpdateSources.preferredKey, value);
                  if (mounted) setState(() => _preferred = value);
                },
                icon: Icon(
                  _preferred == _sources[i].template
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
              ),
              title: Text(_sources[i].name),
              subtitle: Text(_sources[i].template),
              onTap: () => _edit(i),
              trailing: IconButton(
                tooltip: '移除下载源',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (_preferred == _sources[i].template) {
                    await _prefs!.remove(UpdateSources.preferredKey);
                    _preferred = null;
                  }
                  final next = [..._sources]..removeAt(i);
                  await UpdateSources.save(_prefs!, next);
                  if (mounted) setState(() => _sources = next);
                },
              ),
            ),
          ),
        FilledButton.tonalIcon(
          onPressed: _prefs == null ? null : () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('添加下载源'),
        ),
      ],
    ),
  );
}
