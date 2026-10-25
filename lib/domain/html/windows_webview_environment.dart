import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

Future<void>? _environment;
Future<void> ensureWindowsWebviewEnvironment() => _environment ??=
    (() async {
      if (await WebviewController.getWebViewVersion() == null) {
        throw StateError('请安装 Microsoft Edge WebView2 Runtime 后使用内嵌浏览器。');
      }
      final folder = await getApplicationSupportDirectory();
      await folder.create(recursive: true);
      await WebviewController.initializeEnvironment(
        userDataPath: '${folder.path}/code-preview-webview',
      );
    })().catchError((Object error) {
      _environment = null;
      throw error;
    });
