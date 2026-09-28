import 'dart:convert';

/// Arguments are passed directly to the executable, never to a command shell.
class McpProcessConfig {
  const McpProcessConfig({
    required this.command,
    this.arguments = const [],
    this.workingDirectory = '',
  });
  final String command;
  final List<String> arguments;
  final String workingDirectory;
  bool get isConfigured => command.trim().isNotEmpty;
  String get identity => jsonEncode(toJson());
  Map<String, dynamic> toJson() => {
    'command': command,
    'arguments': arguments,
    'workingDirectory': workingDirectory,
  };
  factory McpProcessConfig.fromJson(Map<String, dynamic> json) =>
      McpProcessConfig(
        command: json['command'] is String
            ? (json['command'] as String).trim()
            : '',
        arguments: json['arguments'] is List
            ? (json['arguments'] as List).whereType<String>().toList()
            : const [],
        workingDirectory: json['workingDirectory'] is String
            ? json['workingDirectory'] as String
            : '',
      );
}
