/// Supported API wire formats for LLM and multimodal endpoints.
enum LlmApiFormat {
  /// Use URL hints first; the chat router tries alternative wire formats only
  /// after an explicit protocol rejection, before any response is emitted.
  auto,

  /// OpenAI-compatible REST endpoints (`/chat/completions`, `/images/generations`).
  openAiCompatible,

  /// OpenAI Responses (`/responses`), independently of hosted search.
  openAiResponses,

  /// Anthropic Messages (`/messages`).
  anthropicMessages,

  /// Google Gemini native REST endpoints (`/v1beta/models/{model}:streamGenerateContent`).
  geminiNative;

  String get wire => name;

  String get label => switch (this) {
    LlmApiFormat.auto => '自动识别',
    LlmApiFormat.openAiCompatible => 'OpenAI 兼容 (/chat/completions)',
    LlmApiFormat.openAiResponses => 'OpenAI Responses (/responses)',
    LlmApiFormat.anthropicMessages => 'Anthropic Messages (/messages)',
    LlmApiFormat.geminiNative => 'Gemini 原生 (/v1beta/models)',
  };

  String get shortLabel => switch (this) {
    LlmApiFormat.auto => '自动识别',
    LlmApiFormat.openAiCompatible => 'OpenAI 兼容',
    LlmApiFormat.openAiResponses => 'Responses',
    LlmApiFormat.anthropicMessages => 'Anthropic Messages',
    LlmApiFormat.geminiNative => 'Gemini 原生',
  };

  static LlmApiFormat fromWire(String? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return LlmApiFormat.auto;
  }
}

/// URL detection, normalization, and header helpers for Gemini endpoints
/// (both native `/v1beta/models/...` and OpenAI-compatible `/v1beta/openai`).
abstract final class GeminiEndpoint {
  static const officialGeminiNativeBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';
  static const officialGeminiOpenAiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta/openai';

  static bool isGoogleGeminiHost(String baseUrl) {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
    return host == 'generativelanguage.googleapis.com';
  }

  static bool hasOpenAiCompatPath(String baseUrl) {
    final path = (Uri.tryParse(baseUrl.trim())?.path ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'/+$'), '');
    return path.endsWith('/openai') ||
        path.contains('/openai/') ||
        path.endsWith('/compatible-mode/v1') ||
        path.endsWith('/chat/completions') ||
        path.endsWith('/responses');
  }

  /// True when [baseUrl] looks like a native Gemini API endpoint rather than an
  /// OpenAI-compatible `/v1` or `/v1beta/openai` endpoint.
  static bool looksLikeGeminiNativeUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) return false;
    if (hasOpenAiCompatPath(trimmed)) return false;
    if (isGoogleGeminiHost(trimmed)) return true;
    final path = (Uri.tryParse(trimmed)?.path ?? '').toLowerCase().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    return path.endsWith('/v1beta') ||
        path.endsWith('/v1alpha') ||
        path.contains('/v1beta/models') ||
        path.contains('/v1alpha/models') ||
        path.contains(':generatecontent') ||
        path.contains(':streamgeneratecontent') ||
        path.contains(':predict');
  }

  /// Resolves [format] against [baseUrl], turning [LlmApiFormat.auto] into a
  /// concrete wire protocol ([LlmApiFormat.openAiCompatible] or
  /// [LlmApiFormat.geminiNative]).
  static LlmApiFormat resolveFormat({
    required LlmApiFormat format,
    required String baseUrl,
  }) {
    if (format != LlmApiFormat.auto) return format;
    final uri = Uri.tryParse(baseUrl.trim());
    final path = (uri?.path ?? '').toLowerCase().replaceAll(RegExp(r'/+$'), '');
    if (path.endsWith('/responses')) return LlmApiFormat.openAiResponses;
    if (path.endsWith('/messages') || uri?.host == 'api.anthropic.com') {
      return LlmApiFormat.anthropicMessages;
    }
    return looksLikeGeminiNativeUrl(baseUrl)
        ? LlmApiFormat.geminiNative
        : LlmApiFormat.openAiCompatible;
  }

  /// Normalizes [baseUrl] for OpenAI-compatible requests (`/chat/completions`,
  /// `/images/generations`, etc.).
  ///
  /// When a user enters a bare Google Gemini URL (`generativelanguage.googleapis.com`
  /// or `.../v1beta`) or a `/v1beta` URL and explicitly selects OpenAI-compatible
  /// mode, this automatically appends `/v1beta/openai` or `/openai` so requests
  /// reach the OpenAI compatibility layer.
  static String normalizeOpenAiBaseUrl(String baseUrl) {
    var trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return trimmed;
    for (final suffix in [
      '/chat/completions',
      '/responses',
      '/messages',
      '/images/generations',
      '/images/edits',
    ]) {
      if (trimmed.toLowerCase().endsWith(suffix)) {
        trimmed = trimmed
            .substring(0, trimmed.length - suffix.length)
            .replaceAll(RegExp(r'/+$'), '');
      }
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return trimmed;

    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    for (final suffix in ['/chat/completions', '/responses', '/messages']) {
      if (path.toLowerCase().endsWith(suffix)) {
        path = path.substring(0, path.length - suffix.length);
        break;
      }
    }
    final lowerPath = path.toLowerCase();

    // Strip any accidental `/models/...` tail when converting to OpenAI path.
    final modelsIdx =
        RegExp(r'/models(?:/|$)').firstMatch(lowerPath)?.start ?? -1;
    if (modelsIdx >= 0) {
      path = path.substring(0, modelsIdx).replaceAll(RegExp(r'/+$'), '');
    }

    final cleanLower = path.toLowerCase();
    if (isGoogleGeminiHost(trimmed)) {
      if (cleanLower.endsWith('/openai') || cleanLower.contains('/openai/')) {
        return uri.replace(path: path).toString();
      }
      if (cleanLower.isEmpty) {
        return uri.replace(path: '/v1beta/openai').toString();
      }
      if (RegExp(r'/v\d+[a-z0-9]*$', caseSensitive: false).hasMatch(path)) {
        return uri.replace(path: '$path/openai').toString();
      }
      return uri.replace(path: '$path/v1beta/openai').toString();
    }

    if (cleanLower.endsWith('/v1beta') || cleanLower.endsWith('/v1alpha')) {
      return uri.replace(path: '$path/openai').toString();
    }
    return uri.replace(path: path).toString();
  }

  /// Normalizes [baseUrl] to the Gemini version root (e.g.
  /// `https://generativelanguage.googleapis.com/v1beta`), stripping any
  /// `/openai`, `/models/...`, or `:generateContent` suffixes.
  static String normalizeGeminiVersionBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return trimmed;

    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    for (final suffix in [
      '/chat/completions',
      '/responses',
      '/messages',
      '/images/generations',
      '/images/edits',
      '/openai',
    ]) {
      if (path.toLowerCase().endsWith(suffix)) {
        path = path
            .substring(0, path.length - suffix.length)
            .replaceAll(RegExp(r'/+$'), '');
      }
    }

    final lowerPath = path.toLowerCase();
    final modelsIdx =
        RegExp(r'/models(?:/|$)').firstMatch(lowerPath)?.start ?? -1;
    if (modelsIdx >= 0) {
      path = path.substring(0, modelsIdx).replaceAll(RegExp(r'/+$'), '');
    }

    if (!RegExp(r'/v\d+[a-z0-9]*$', caseSensitive: false).hasMatch(path)) {
      path = '$path/v1beta';
    }

    return uri.replace(path: path).toString();
  }

  /// Strips leading `models/` or aggregator `google/` prefixes from [model].
  static String normalizeModelId(String model) {
    var clean = model.trim();
    if (clean.toLowerCase().startsWith('models/')) {
      clean = clean.substring('models/'.length).trim();
    }
    if (clean.toLowerCase().startsWith('google/')) {
      clean = clean.substring('google/'.length).trim();
    }
    return clean;
  }

  /// Builds `{versionBase}/models/{modelId}:{method}` (with `?alt=sse` when
  /// [sse] is true).
  static String modelEndpoint(
    String baseUrl,
    String model,
    String method, {
    bool sse = false,
  }) {
    final base = normalizeGeminiVersionBaseUrl(baseUrl);
    final modelId = Uri.encodeComponent(normalizeModelId(model));
    final uri = Uri.parse(base);
    final url = Uri.parse(
      '${uri.scheme}://${uri.authority}${uri.path}/models/$modelId:$method',
    ).replace(query: uri.hasQuery ? uri.query : null);
    return sse
        ? url
              .replace(queryParameters: {...uri.queryParameters, 'alt': 'sse'})
              .toString()
        : url.toString();
  }

  /// Cleans user-entered Base URLs when they paste a full Gemini action URL
  /// such as `https://.../v1beta/models/gemini-2.5-flash:generateContent`.
  static String cleanUserInputBaseUrl(String raw) {
    final trimmed = raw.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return trimmed;
    final lowerPath = uri.path.toLowerCase();
    if (lowerPath.contains('/models/') ||
        lowerPath.endsWith('/models') ||
        lowerPath.contains(':generatecontent') ||
        lowerPath.contains(':streamgeneratecontent') ||
        lowerPath.contains(':predict')) {
      return normalizeGeminiVersionBaseUrl(
        '${uri.scheme}://${uri.authority}${uri.path}',
      );
    }
    return trimmed;
  }

  /// Authentication headers for Gemini native requests.
  ///
  /// The official Gemini endpoint requires `x-goog-api-key` for API
  /// keys and reject `Authorization: Bearer AIza...` as an invalid OAuth2 token.
  /// Third-party relays (OneAPI/NewAPI/LiteLLM) may check either `x-goog-api-key`
  /// or `Authorization: Bearer`, so non-Google hosts with non-`AIza` keys send
  /// both headers.
  static Map<String, String> headers(
    String baseUrl,
    String apiKey, {
    String accept = 'application/json',
  }) {
    final key = apiKey.trim();
    final map = <String, String>{
      'x-goog-api-key': key,
      'Content-Type': 'application/json',
      'Accept': accept,
    };
    if (!isGoogleGeminiHost(baseUrl) && !key.startsWith('AIza')) {
      map['Authorization'] = 'Bearer $key';
    }
    return map;
  }
}
