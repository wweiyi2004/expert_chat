import 'package:dio/dio.dart';
import 'command_runner_contract.dart';

Future<String> runWorkspaceCommand(
  String command,
  String directory,
  Duration timeout,
  CancelToken token, {
  WorkspaceCommandOutput? onOutput,
  WorkspaceCommandCompletion? onComplete,
}) => throw UnsupportedError('当前平台不支持本机命令');
