/// Raised when a model answered successfully but did not return the structured
/// JSON required by a study feature, even after one corrective retry.
class StudyStructuredOutputException implements Exception {
  const StudyStructuredOutputException({
    required this.feature,
    required this.rawOutput,
    this.cause,
  });

  final String feature;
  final String rawOutput;
  final Object? cause;

  @override
  String toString() => '$feature返回的内容无法识别。已自动重试一次，请重试或更换模型。';
}
