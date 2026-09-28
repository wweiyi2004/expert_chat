import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../domain/errors/app_failure.dart';
import '../../domain/support/diagnostic_report.dart';
import '../../domain/support/diagnostic_trace.dart';
import '../../domain/update/app_update.dart' show kGithubOwner, kGithubRepo;
import '../shared/recovery_notice.dart';

class SupportPage extends StatefulWidget {
  const SupportPage({
    super.key,
    this.initialError,
    this.readCounts,
    this.readInfo = DiagnosticInfo.load,
    this.openFeedback,
  });
  final Object? initialError;
  final Future<Map<String, int>> Function()? readCounts;
  final Future<DiagnosticInfo> Function() readInfo;
  final Future<bool> Function(Uri)? openFeedback;
  static final feedbackUri = Uri.parse(
    'https://github.com/$kGithubOwner/$kGithubRepo/issues/new',
  );
  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  bool _includeCounts = false;
  bool _loading = true;
  int _request = 0;
  DiagnosticReport? _report;
  Object? _error;
  String? _notice;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    final include = _includeCounts;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await widget.readInfo();
      Map<String, int>? counts;
      FailureKind? countError;
      if (include && widget.readCounts != null) {
        try {
          counts = await widget.readCounts!().timeout(
            const Duration(seconds: 3),
          );
        } catch (e) {
          countError = AppFailure.from(e).kind;
        }
      }
      if (!mounted || request != _request) return;
      setState(() {
        _report = DiagnosticReport(
          info: info,
          countsRequested: include,
          counts: counts,
          countsFailure: countError,
          failure: widget.initialError == null
              ? null
              : AppFailure.from(widget.initialError!).kind,
        );
        _loading = false;
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _copy() async {
    final report = _report;
    if (_loading || report == null) return;
    try {
      await Clipboard.setData(
        ClipboardData(
          text: report.toText() + DiagnosticTrace.instance.exportText(),
        ),
      );
      if (mounted) setState(() => _notice = '已复制。请在反馈页面补充问题描述，并检查内容后提交。');
    } catch (_) {
      if (mounted) setState(() => _notice = '复制失败，请在下方摘要中选择文字并手动复制。');
    }
  }

  Future<void> _open() async {
    try {
      final opened = widget.openFeedback == null
          ? await launchUrl(
              SupportPage.feedbackUri,
              mode: LaunchMode.externalApplication,
            )
          : await widget.openFeedback!(SupportPage.feedbackUri);
      if (!opened && mounted) {
        setState(() => _notice = '无法打开浏览器，请复制下方反馈地址后手动访问。');
      }
    } catch (_) {
      if (mounted) setState(() => _notice = '无法打开浏览器，请复制下方反馈地址后手动访问。');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('帮助与反馈')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '把问题说明白，方便定位',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text('复制诊断摘要，再到反馈页面补充操作步骤、期望结果和实际结果。'),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '你可以先检查',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '连接失败：在设置 → 模型中验证连接。\n资料或历史读取失败：先保留应用数据，再检查存储空间。\n换机或重装前：在设置 → 数据中导出完整备份。',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('摘要默认仅含版本、平台和错误类别，不包含聊天内容、密钥、文件名或服务地址。应用不会自动发送或提交报告。'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('记录本次运行的诊断步骤'),
                subtitle: const Text(
                  '仅记录阶段与耗时，不包含聊天内容；关闭或退出应用后清空。开启后可返回聊天复现问题。',
                ),
                value: DiagnosticTrace.instance.enabled,
                onChanged: (value) =>
                    setState(() => DiagnosticTrace.instance.setEnabled(value)),
              ),
              if (widget.readCounts != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('包含本地数据数量'),
                  subtitle: const Text('仅统计数量，不包含具体内容'),
                  value: _includeCounts,
                  onChanged: (value) {
                    setState(() => _includeCounts = value ?? false);
                    _load();
                  },
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _loading || _report == null ? null : _copy,
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('复制诊断摘要'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _open,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('打开反馈页面'),
                  ),
                ],
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(_notice!),
                ),
              const SizedBox(height: 20),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null)
                RecoveryNotice(
                  error: _error!,
                  title: '摘要暂时无法生成',
                  onRetry: _load,
                ),
              if (_report != null && !_loading)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '诊断摘要预览',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        SelectableText(
                          _report!.toText() +
                              DiagnosticTrace.instance.exportText(),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              const Text('反馈地址'),
              SelectableText(SupportPage.feedbackUri.toString()),
            ],
          ),
        ),
      ),
    ),
  );
}
