import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../../../core/providers.dart';
import '../../../data/provider_profile.dart';
import '../../../domain/llm/llm_provider.dart';
import '../../../domain/llm/magpie_companion.dart';
import '../../../state/settings_controller.dart';

final magpieCompanionProvider = Provider((ref) => MagpieCompanion());

class MagpieCompanionPanel extends ConsumerStatefulWidget {
  const MagpieCompanionPanel({super.key});
  @override
  ConsumerState<MagpieCompanionPanel> createState() => _CompanionState();
}

class _CompanionState extends ConsumerState<MagpieCompanionPanel> {
  final _executable = TextEditingController(),
      _api = TextEditingController(text: '3425'),
      _web = TextEditingController(text: '3430');
  bool _busy = false;
  String _status = '默认未启用；不自动读取其他程序的订阅登录';
  @override
  void initState() {
    super.initState();
    try {
      final raw = ref.read(sharedPrefsProvider).getString('magpieCompanion.v1');
      if (raw != null) {
        final data = jsonDecode(raw) as Map;
        _executable.text = data['executable'] as String? ?? '';
        _api.text = '${data['apiPort'] ?? 3425}';
        _web.text = '${data['webPort'] ?? 3430}';
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _executable.dispose();
    _api.dispose();
    _web.dispose();
    super.dispose();
  }

  Future<void> _action(Future<void> Function() operation) async {
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _status = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final companion = ref.read(magpieCompanionProvider);
    return ExpansionTile(
      title: const Text('可选 Magpie 订阅伴随服务'),
      subtitle: const Text('独立第三方组件 · 显式启动/登录 · 通过本机网关路由'),
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Expert Chat 原生支持 ChatGPT SIWC。其他订阅可选择由 Magpie 自己提供的登录方式，再通过其本机网关使用；不代表本应用原生 OAuth。需要自行安装官方 Magpie CLI（MIT）。启动固定关闭自动账号发现和遥测，不导入其他 CLI 登录；真实账号激活仅在你点击管理并授权后进行。',
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _executable,
            enabled: !_busy && !companion.owned,
            decoration: const InputDecoration(
              labelText: 'Magpie CLI 可执行文件绝对路径（不含参数）',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _api,
                  enabled: !_busy && !companion.owned,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '本机 API 端口'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _web,
                  enabled: !_busy && !companion.owned,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '本机管理端口'),
                ),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _busy || companion.owned
                  ? null
                  : () => _action(() async {
                      final api = int.parse(_api.text),
                          web = int.parse(_web.text);
                      final executable = _executable.text.trim();
                      final prefs = ref.read(sharedPrefsProvider);
                      final support = await getApplicationSupportDirectory();
                      final models = await companion.start(
                        executable: executable,
                        directory: p.join(support.path, 'companions', 'magpie'),
                        apiPort: api,
                        webPort: web,
                      );
                      await prefs.setString(
                        'magpieCompanion.v1',
                        jsonEncode({
                          'executable': executable,
                          'apiPort': api,
                          'webPort': web,
                        }),
                      );
                      if (mounted) {
                        setState(
                          () => _status =
                              '自持进程与两个本机监听端口已核验；发现 ${models.length} 个模型。${models.isEmpty ? '尚无可用模型，请在管理页面配置账号/服务。' : ''}',
                        );
                      }
                    }),
              child: const Text('显式启动伴随服务'),
            ),
            OutlinedButton(
              onPressed: _busy || !companion.owned
                  ? null
                  : () => _action(
                      () => companion.openManagement(
                        (uri) => launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ),
              child: const Text('打开账号/订阅管理'),
            ),
            OutlinedButton(
              onPressed: _busy || !companion.owned
                  ? null
                  : () => _action(() async {
                      final apiPort = _api.text;
                      final models = await companion.models();
                      if (!mounted) return;
                      if (models.isEmpty) {
                        throw StateError('网关健康，但尚无已配置模型；先在伴随服务完成账号配置');
                      }
                      final settings = ref
                          .read(settingsControllerProvider)
                          .requireValue;
                      final existing = settings.profiles
                          .where(
                            (profile) =>
                                profile.id == 'magpie-companion-managed-v1',
                          )
                          .firstOrNull;
                      await ref
                          .read(settingsControllerProvider.notifier)
                          .saveModelService(
                            ProviderProfile(
                              id: 'magpie-companion-managed-v1',
                              name: existing?.name ?? 'Magpie 伴随网关',
                              baseUrl: 'http://127.0.0.1:$apiPort/v1',
                              chatModel: models.contains(existing?.chatModel)
                                  ? existing!.chatModel
                                  : models.first,
                              reasonerModel:
                                  models.contains(existing?.reasonerModel)
                                  ? existing!.reasonerModel
                                  : models.first,
                              models: models,
                              apiFormat: LlmApiFormat.openAiCompatible,
                            ),
                            'magpie',
                          );
                      if (mounted) {
                        setState(
                          () => _status =
                              '已扫描 ${models.length} 个真实模型并保存本机网关渠道；可在会话模型列表选择。',
                        );
                      }
                    }),
              child: const Text('扫描并接入模型渠道'),
            ),
            TextButton(
              onPressed: _busy || !companion.owned
                  ? null
                  : () => _action(() async {
                      await companion.stopOwned();
                      if (mounted) {
                        setState(
                          () =>
                              _status = '仅已停止本次启动的伴随进程；配置与账号保留。正在使用该渠道的请求可能中断。',
                        );
                      }
                    }),
              child: const Text('停止本次启动的服务'),
            ),
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://github.com/yetone/magpie/releases'),
                mode: LaunchMode.externalApplication,
              ),
              child: const Text('官方安装与许可证'),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(_busy ? '处理中…\n$_status' : _status),
        ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '使用应用专用 XDG 配置/缓存目录；不承诺第三方组件的系统凭据保险库与其他应用隔离。管理链接含临时私密令牌，仅由系统浏览器打开，不写入日志、模型渠道或设置导出。端口冲突时不会接管既有服务，可使用自定义 Base URL 显式连接已有网关。',
          ),
        ),
      ],
    );
  }
}
