import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../settings/support_page.dart';
import '../shared/recovery_notice.dart';

/// Shown only when prefs/DB bootstrap throws — better than a silent crash.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '启动失败',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text(
                  '本地数据初始化出错。请保留应用数据与恢复日志，不要清除数据或重装；可重启后重试，或把下面信息反馈给开发者。',
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: RecoveryNotice(error: error, title: '本地数据初始化未完成'),
                  ),
                ),
                const SizedBox(height: 16),
                Builder(
                  builder: (pageContext) => FilledButton.icon(
                    onPressed: () => Navigator.push(
                      pageContext,
                      MaterialPageRoute<void>(
                        builder: (_) => SupportPage(initialError: error),
                      ),
                    ),
                    icon: const Icon(Icons.info_outline),
                    label: const Text('生成诊断摘要'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
