class ApprovalVerdict {
  const ApprovalVerdict(this.verdict, this.reason);
  final String verdict, reason;
  bool get approved => verdict == 'approve';
  factory ApprovalVerdict.fromJson(Object? input) {
    if (input is! Map ||
        input.keys.any((key) => !['verdict', 'reason'].contains(key)) ||
        !['approve', 'reject', 'unknown'].contains(input['verdict']) ||
        input['reason'] is! String ||
        (input['reason'] as String).trim().isEmpty ||
        (input['reason'] as String).length > 1000) {
      return const ApprovalVerdict('unknown', '审查结果不符合严格格式，需要人工批准');
    }
    return ApprovalVerdict(
      input['verdict'] as String,
      input['reason'] as String,
    );
  }
}
