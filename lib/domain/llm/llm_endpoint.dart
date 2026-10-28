import 'gemini_endpoint.dart';

/// Normalizes user-entered API roots or complete action URLs without changing
/// the origin or discarding a relay's path prefix/query parameters.
abstract final class LlmEndpoint {
  static String base(String input) {
    final uri = Uri.parse(input.trim());
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    for (final suffix in ['/chat/completions', '/responses', '/messages']) {
      if (path.toLowerCase().endsWith(suffix)) {
        path = path.substring(0, path.length - suffix.length);
        break;
      }
    }
    if (path.isEmpty &&
        {'api.openai.com', 'api.anthropic.com'}.contains(uri.host)) {
      path = '/v1';
    }
    if (uri.scheme == 'https' &&
        uri.host.toLowerCase() == 'openrouter.ai' &&
        {'', '/api'}.contains(path)) {
      path = '/api/v1';
    }
    return uri.replace(path: path).removeFragment().toString();
  }

  static String action(String input, String action) {
    final uri = Uri.parse(base(input));
    return uri.replace(path: '${uri.path}/$action').toString();
  }

  static List<String> roots(String input, {LlmApiFormat? format}) {
    final root = base(input);
    final uri = Uri.parse(root);
    if (format == LlmApiFormat.geminiNative) {
      return [
        root,
        if (uri.path.endsWith('/v1'))
          uri
              .replace(
                path: '${uri.path.substring(0, uri.path.length - 3)}/v1beta',
              )
              .toString(),
      ];
    }
    return [root, if (uri.path.isEmpty) uri.replace(path: '/v1').toString()];
  }

  static String helperText(LlmApiFormat format, String baseUrl) {
    if (format == LlmApiFormat.auto) {
      return '优先按地址识别；接口不兼容时自动尝试其他协议，成功后在本次运行中复用。';
    }
    return switch (format) {
      LlmApiFormat.openAiResponses => '使用 Responses 协议 (/responses)，无需开启联网搜索',
      LlmApiFormat.anthropicMessages => '使用 Anthropic Messages 协议 (/messages)',
      LlmApiFormat.geminiNative =>
        '使用 Gemini 原生协议 (/v1beta/models/{model}:streamGenerateContent)',
      _ =>
        GeminiEndpoint.isGoogleGeminiHost(baseUrl)
            ? '使用 Gemini OpenAI 兼容路径 (/v1beta/openai/chat/completions)'
            : '使用 OpenAI 兼容协议 (/chat/completions)',
    };
  }
}
