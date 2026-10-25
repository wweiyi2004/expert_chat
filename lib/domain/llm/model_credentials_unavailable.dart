/// An expected activation failure, distinct from transport or programming
/// errors. Contains a fixed reason only, never account tokens or server bodies.
class ModelCredentialsUnavailable implements Exception {
  const ModelCredentialsUnavailable(this.reason);
  final String reason;
  @override
  String toString() => '模型渠道尚未激活或需重新登录（$reason）';
}
