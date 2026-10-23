import 'dart:convert';

/// Arguments are passed directly to the executable, never to a command shell.
class McpProcessConfig {
  const McpProcessConfig({
    required this.command,
    this.arguments = const [],
    this.workingDirectory = '',
    this.sessionScoped = false,
    this.preset = '',
  });
  final String command;
  final List<String> arguments;
  final String workingDirectory;

  /// Separate subprocesses for each conversation/agent. Browser state must not
  /// leak through the application's otherwise shared MCP client.
  final bool sessionScoped;
  final String preset;
  bool get isPlaywright => preset == 'playwright';
  bool get requiresSession => sessionScoped || isPlaywright;
  bool get isConfigured => command.trim().isNotEmpty;
  String get identity => jsonEncode(toJson());
  Map<String, dynamic> toJson() => {
    'command': command,
    'arguments': arguments,
    'workingDirectory': workingDirectory,
    if (sessionScoped) 'sessionScoped': true,
    if (preset.isNotEmpty) 'preset': preset,
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
        sessionScoped: json['sessionScoped'] == true,
        preset: json['preset'] is String ? json['preset'] as String : '',
      );
}
