class CacheClearResult {
  const CacheClearResult({
    this.filesRemoved = 0,
    this.bytesRemoved = 0,
    this.failures = 0,
  });

  final int filesRemoved;
  final int bytesRemoved;
  final int failures;
}
