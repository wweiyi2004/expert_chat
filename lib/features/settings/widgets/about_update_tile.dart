import 'package:flutter/material.dart';

import 'package:package_info_plus/package_info_plus.dart';

import '../../../domain/update/shorebird_patch.dart';
import '../../../domain/update/shorebird_ui.dart';
import '../../../domain/update/update_ui.dart';
import '../update_sources_page.dart';

class AboutUpdateTile extends StatefulWidget {
  const AboutUpdateTile({super.key});

  @override
  State<AboutUpdateTile> createState() => _AboutUpdateTileState();
}

class _AboutUpdateTileState extends State<AboutUpdateTile> {
  String _version = '…';
  String _patchLabel = '补丁：检测中…';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then(
      (info) {
        if (!mounted) return;
        setState(() => _version = 'v${info.version} (${info.buildNumber})');
      },
      onError: (Object _) {
        if (mounted) setState(() => _version = '版本信息不可用');
      },
    );
    final patchService = ShorebirdPatchService();
    if (!patchService.isAvailable) {
      _patchLabel = '代码补丁：当前安装包未启用 Shorebird';
    }
    patchService.currentPatchNumber().then((n) {
      if (!mounted) return;
      setState(() {
        _patchLabel = !patchService.isAvailable
            ? '代码补丁：当前安装包未启用 Shorebird'
            : n == null
            ? '代码补丁：基座版本（暂无补丁）'
            : '代码补丁：#$n';
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Expert Chat'),
            subtitle: Text('$_version\n$_patchLabel'),
            isThreeLine: true,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.bolt_outlined),
            title: const Text('检查代码补丁'),
            subtitle: const Text('重启应用后生效'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => checkShorebirdPatchInteractive(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('检查整包更新'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => checkForUpdatesInteractive(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.cloud_download_outlined),
            title: const Text('更新下载源'),
            subtitle: const Text('断点续传 · Gitee / 自定义镜像'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const UpdateSourcesPage(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
