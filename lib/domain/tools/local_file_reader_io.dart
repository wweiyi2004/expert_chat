import 'dart:io';

Stream<List<int>>? openLocalFileReadStreamImpl(String? path) {
  if (path == null || path.isEmpty) return null;
  return File(path).openRead();
}
