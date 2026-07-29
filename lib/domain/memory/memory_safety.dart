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
    if (RegExp(
      r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
      caseSensitive: false,
    ).hasMatch(text)) {
      return '私钥内容';
    }
    if (RegExp(
      r'\bBearer\s+[A-Za-z0-9._~+/=-]{12,}',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'Bearer Token';
    }
    if (RegExp(
      r'\b(?:api[_ -]?key|access[_ -]?token|secret|password|passwd)'
      r'''\s*[:=]\s*["']?[^\s"']{6,}''',
      caseSensitive: false,
    ).hasMatch(text)) {
      return '密钥或密码';
    }
    if (RegExp(r'\bsk-[A-Za-z0-9_-]{12,}\b').hasMatch(text)) {
      return 'API Key';
    }
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
