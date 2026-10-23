import 'terminal_connection.dart';

Future<TerminalConnection> openLocalTerminal(
  String root,
  int columns,
  int rows,
) => throw UnsupportedError('浏览器中无法启动本机终端，请使用桌面应用。');
