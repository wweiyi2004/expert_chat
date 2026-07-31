/// Validation and secret detection applied before anything reaches the
/// plaintext Markdown memory file.
class MemorySafety {
  const MemorySafety._();

  static const int maxContentChars = 1200;

  static String normalize(String raw) {
    final normalized = raw
        .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) {
      throw const MemoryValidationException('记忆内容不能为空。');
    }
    if (normalized.length > maxContentChars) {
      throw const MemoryValidationException('单条记忆不能超过 1200 个字符。');
    }
    final sensitive = sensitiveReason(normalized);
    if (sensitive != null) {
      throw MemoryValidationException('检测到$sensitive，已阻止写入记忆文件。');
    }
    return normalized;
  }

  static String? sensitiveReason(String text) {
    // PEM 私钥头。
    if (RegExp(
      r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
      caseSensitive: false,
    ).hasMatch(text)) {
      return '私钥内容';
    }
    // Bearer Token:值 >= 12 字符且至少含一个数字或符号,避免把
    // "Bearer authentication" 这类纯字母英文短语误拦。
    if (RegExp(
      r'\bBearer\s+(?=[A-Za-z0-9._~+/=-]{12,})'
      r'(?=[A-Za-z0-9._~+/=-]*[0-9._~+/-])[A-Za-z0-9._~+/=-]+',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'Bearer Token';
    }
    // 英文标签键值对:api key / access token / secret / password / passwd。
    // 值 >= 6 字符且至少含一个 ASCII 字母或数字,避免把
    // "secret = 必填字段" 这类中文说明文字误拦。
    if (RegExp(
      r'\b(?:api[_ -]?key|access[_ -]?token|secret|password|passwd)'
      r'''\s*[:=]\s*["']?(?=[^\s"']{6,})(?=[^\s"']*[A-Za-z0-9])[^\s"']*''',
      caseSensitive: false,
    ).hasMatch(text)) {
      return '密钥或密码';
    }
    // 裸 token 标签:token / access_token / auth_token,值 >= 3 字符。
    if (RegExp(
      r'\b(?:access[_ -]?|auth[_ -]?)?token'
      r'''\s*[:=]\s*["']?(?=[^\s"']{3,})(?=[^\s"']*[A-Za-z0-9])[^\s"']*''',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'Token 凭证';
    }
    // 中文标签:密码 / 密钥 / 口令 / 秘钥(含 api key,支持全角冒号)。
    // 值需含 ASCII 字母或数字,避免把"密码 = 必填字段"这类表单说明误拦。
    if (RegExp(
      r'(?:密码|密钥|口令|秘钥|api[ _-]?key)'
      r'''\s*[=:：]\s*["']?(?=[^\s"']{3,})(?=[^\s"']*[A-Za-z0-9])[^\s"']*''',
    ).hasMatch(text)) {
      return '密钥或口令';
    }
    // OpenAI 风格 sk- 前缀。
    if (RegExp(r'\bsk-[A-Za-z0-9_-]{12,}\b').hasMatch(text)) {
      return 'API Key';
    }
    // Google/Gemini API key:AIzaSy + 30 字符以上。
    if (RegExp(r'\bAIzaSy[0-9A-Za-z_-]{30,}').hasMatch(text)) {
      return 'API Key';
    }
    // HuggingFace token:hf_ + 10 字符以上字母数字。
    if (RegExp(r'\bhf_[A-Za-z0-9]{10,}').hasMatch(text)) {
      return 'HuggingFace Token';
    }
    // Groq API key:gsk_ + 10 字符以上字母数字。
    if (RegExp(r'\bgsk_[A-Za-z0-9]{10,}').hasMatch(text)) {
      return 'Groq API Key';
    }
    // xAI API key:xai- + 10 字符以上 base64url 字符。
    if (RegExp(r'\bxai-[A-Za-z0-9_-]{10,}').hasMatch(text)) {
      return 'xAI API Key';
    }
    // JWT:eyJ 开头的三段 base64url,每段至少 6 字符。
    if (RegExp(
      r'\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}',
    ).hasMatch(text)) {
      return 'JWT Token';
    }
    // 带账号密码的 URL。
    if (RegExp(
      r'(?:https?|ssh)://[^/\s:@]+:[^/\s@]+@',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'URL 中的登录凭证';
    }
    return null;
  }
}

class MemoryValidationException implements Exception {
  const MemoryValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}
