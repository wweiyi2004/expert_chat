import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Uncompressed, bounded archive: magic + JSON length + SHA-256 + JSON.
/// No archive paths are extracted; no ZIP decompression or executable entries.
class BackupCodec {
  static const maxBytes = 128 * 1024 * 1024;
  static const version = 1;
  static const _magic = [69, 67, 66, 65, 67, 75, 85, 80]; // ECBACKUP
  static const _headerSize = 44;

  static Uint8List encode(Map<String, dynamic> payload) {
    final body = utf8.encode(jsonEncode(payload));
    if (body.length + _headerSize > maxBytes) {
      throw const FormatException('备份超过 128 MB 上限，请先分开导出大型会话或素材。');
    }
    final result = Uint8List(_headerSize + body.length);
    result.setAll(0, _magic);
    ByteData.sublistView(result).setUint32(8, body.length);
    result.setAll(12, sha256.convert(body).bytes);
    result.setAll(_headerSize, body);
    return result;
  }

  static Map<String, dynamic> decode(Uint8List bytes) {
    if (bytes.length < _headerSize || bytes.length > maxBytes) {
      throw const FormatException('备份大小不合法（上限 128 MB）。');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        throw const FormatException('不是 Expert Chat 完整备份。');
      }
    }
    if (ByteData.sublistView(bytes).getUint32(8) !=
        bytes.length - _headerSize) {
      throw const FormatException('备份被截断或包含多余数据。');
    }
    final body = Uint8List.sublistView(bytes, _headerSize);
    final digest = sha256.convert(body).bytes;
    for (var i = 0; i < digest.length; i++) {
      if (digest[i] != bytes[12 + i]) {
        throw const FormatException('备份校验失败，数据已损坏。');
      }
    }
    final result = jsonDecode(utf8.decode(body));
    if (result is! Map<String, dynamic> || result['version'] != version) {
      throw const FormatException('不支持的备份版本，请使用兼容版本的应用。');
    }
    return result;
  }
}
