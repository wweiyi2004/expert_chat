import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_pty2/flutter_pty2.dart';

const benchmarkSizes = <int>[
  1,
  16,
  64,
  1024,
  4096,
  16384,
  65536,
  1024 * 1024,
];

int benchmarkIterations() {
  return benchmarkEnvironmentInt('PTY_BENCHMARK_ITERATIONS', fallback: 5);
}

int benchmarkWarmups() {
  return benchmarkEnvironmentInt('PTY_BENCHMARK_WARMUPS', fallback: 1);
}

List<int> benchmarkSessionCounts() {
  final rawValue = Platform.environment['PTY_BENCHMARK_SESSION_COUNTS'];
  if (rawValue == null || rawValue.isEmpty) {
    return const [1, 10, 50, 100];
  }
  final counts = <int>[];
  for (final rawCount in rawValue.split(',')) {
    final count = int.tryParse(rawCount.trim());
    if (count == null || count < 1) {
      throw ArgumentError.value(
        rawValue,
        'PTY_BENCHMARK_SESSION_COUNTS',
        'must be a comma-separated list of positive integers',
      );
    }
    counts.add(count);
  }
  return List<int>.unmodifiable(counts);
}

int benchmarkEnvironmentInt(String name, {required int fallback}) {
  final rawValue = Platform.environment[name];
  if (rawValue == null || rawValue.isEmpty) return fallback;

  final value = int.tryParse(rawValue);
  if (value == null || value < 1) {
    throw ArgumentError.value(
      rawValue,
      name,
      'must be a positive integer',
    );
  }
  return value;
}

String benchmarkEnvironment(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw StateError('Set $name before running the PTY benchmark.');
  }
  return value;
}

String describeBenchmarkError(Object error) {
  if (error case PtyException(:final nativeError?)) {
    return '$error; native=${nativeError.kind} '
        'domain=${nativeError.domain} code=${nativeError.code} '
        'message=${nativeError.message}';
  }
  return '$error';
}

PtySpawnOptions benchmarkFixtureOptions(
  List<String> arguments, {
  int inputBufferBytes = 1024 * 1024,
  int outputWindowBytes = 256 * 1024,
}) {
  return PtySpawnOptions(
    executable: benchmarkEnvironment('PTY_TEST_CHILD'),
    arguments: List<String>.unmodifiable(arguments),
    inputBufferBytes: inputBufferBytes,
    outputWindowBytes: outputWindowBytes,
  );
}

Uint8List benchmarkPattern(int length) {
  final data = Uint8List(length);
  for (var index = 0; index < length; index++) {
    data[index] = index % 251;
  }
  return data;
}

Future<Uint8List> collectBenchmarkOutput(PtySession session) async {
  final bytes = await session.output.fold<List<int>>(
    <int>[],
    (collected, chunk) => collected..addAll(chunk),
  );
  return Uint8List.fromList(bytes);
}

Future<BenchmarkSummary> runBenchmark(
  String name,
  Future<Duration> Function() sample, {
  int? iterations,
}) async {
  final warmups = benchmarkWarmups();
  final count = iterations ?? benchmarkIterations();
  for (var index = 0; index < warmups; index++) {
    await sample();
  }

  final samples = <Duration>[];
  for (var index = 0; index < count; index++) {
    samples.add(await sample());
  }
  return BenchmarkSummary(name, samples);
}

Future<BenchmarkRun> runBenchmarkWithCpu(
  String name,
  Future<Duration> Function() sample, {
  int? iterations,
}) async {
  final before = readCurrentProcessCpuTime();
  final stopwatch = Stopwatch()..start();
  final summary = await runBenchmark(name, sample, iterations: iterations);
  stopwatch.stop();
  final after = readCurrentProcessCpuTime();
  final cpuUsage = switch ((before, after)) {
    (final before?, final after?) => BenchmarkCpuUsage(
        userMicroseconds: after.userMicroseconds - before.userMicroseconds,
        systemMicroseconds:
            after.systemMicroseconds - before.systemMicroseconds,
        wallMicroseconds: stopwatch.elapsedMicroseconds,
      ),
    _ => null,
  };
  return BenchmarkRun(summary, cpuUsage);
}

void writeBenchmarkHeader() {
  stdout.writeln(
    'name,bytes,sessions,min_us,p50_us,p95_us,mean_us,mean_mib_per_sec,'
    'cpu_user_us,cpu_system_us,cpu_total_us,cpu_util_percent',
  );
}

void writeBenchmark(
  BenchmarkSummary summary, {
  int? bytes,
  int? sessions,
  BenchmarkCpuUsage? cpuUsage,
}) {
  final columns = <String>[summary.name];
  switch (bytes) {
    case final value?:
      columns.add('$value');
    case null:
      columns.add('');
  }
  switch (sessions) {
    case final value?:
      columns.add('$value');
    case null:
      columns.add('');
  }
  columns.addAll([
    '${summary.minimum.inMicroseconds}',
    '${summary.percentile(50).inMicroseconds}',
    '${summary.percentile(95).inMicroseconds}',
    summary.mean.inMicroseconds.toStringAsFixed(1),
    switch (bytes) {
      final value? => meanMiBPerSecond(summary, value).toStringAsFixed(2),
      null => '',
    },
  ]);
  switch (cpuUsage) {
    case final usage?:
      columns.addAll([
        '${usage.userMicroseconds}',
        '${usage.systemMicroseconds}',
        '${usage.totalMicroseconds}',
        usage.utilizationPercent.toStringAsFixed(2),
      ]);
    case null:
      columns.addAll(['', '', '', '']);
  }
  stdout.writeln(columns.join(','));
}

BenchmarkCpuTime? readCurrentProcessCpuTime() {
  if (Platform.isWindows) return _readWindowsCpuTime();
  return _readPosixCpuTime();
}

BenchmarkCpuTime? _readPosixCpuTime() {
  final pointer = calloc<Uint8>(256);
  try {
    final getrusage = DynamicLibrary.process().lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)>('getrusage');
    if (getrusage(0, pointer) != 0) return null;
    final values = pointer.cast<Int64>();
    return BenchmarkCpuTime(
      userMicroseconds: _timevalMicroseconds(values[0], values[1]),
      systemMicroseconds: _timevalMicroseconds(values[2], values[3]),
    );
  } on Object {
    return null;
  } finally {
    calloc.free(pointer);
  }
}

BenchmarkCpuTime? _readWindowsCpuTime() {
  try {
    final library = DynamicLibrary.open('kernel32.dll');
    final getCurrentProcess = library.lookupFunction<Pointer<Void> Function(),
        Pointer<Void> Function()>('GetCurrentProcess');
    final getProcessTimes = library.lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
        )>('GetProcessTimes');
    final fileTimes = calloc<Uint32>(8);
    try {
      final ok = getProcessTimes(
        getCurrentProcess(),
        fileTimes,
        fileTimes + 2,
        fileTimes + 4,
        fileTimes + 6,
      );
      if (ok == 0) return null;
      return BenchmarkCpuTime(
        userMicroseconds: _filetimeMicroseconds(fileTimes + 6),
        systemMicroseconds: _filetimeMicroseconds(fileTimes + 4),
      );
    } finally {
      calloc.free(fileTimes);
    }
  } on Object {
    return null;
  }
}

int _timevalMicroseconds(int seconds, int microseconds) {
  return seconds * Duration.microsecondsPerSecond + microseconds;
}

int _filetimeMicroseconds(Pointer<Uint32> fileTime) {
  final ticks = (fileTime[1] << 32) | fileTime[0];
  return ticks ~/ 10;
}

double meanMiBPerSecond(BenchmarkSummary summary, int bytes) {
  final microseconds = math.max(summary.mean.inMicroseconds, 1);
  return bytes * 1000000 / microseconds / (1024 * 1024);
}

final class BenchmarkSummary {
  BenchmarkSummary(this.name, List<Duration> samples)
      : samples = List<Duration>.unmodifiable(samples) {
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', 'must not be empty');
    }
  }

  final String name;
  final List<Duration> samples;

  Duration get minimum {
    return samples.reduce(
      (first, second) => switch (first <= second) {
        true => first,
        false => second,
      },
    );
  }

  Duration get mean {
    final total = samples.fold<int>(
      0,
      (microseconds, sample) => microseconds + sample.inMicroseconds,
    );
    return Duration(microseconds: total ~/ samples.length);
  }

  Duration percentile(int percentile) {
    if (percentile < 0 || percentile > 100) {
      throw ArgumentError.value(percentile, 'percentile');
    }
    final sorted = List<Duration>.of(samples)
      ..sort((first, second) => first.compareTo(second));
    final index = ((sorted.length - 1) * percentile / 100).round();
    return sorted[index];
  }
}

final class BenchmarkRun {
  const BenchmarkRun(this.summary, this.cpuUsage);

  final BenchmarkSummary summary;
  final BenchmarkCpuUsage? cpuUsage;
}

final class BenchmarkCpuTime {
  const BenchmarkCpuTime({
    required this.userMicroseconds,
    required this.systemMicroseconds,
  });

  final int userMicroseconds;
  final int systemMicroseconds;
}

final class BenchmarkCpuUsage {
  const BenchmarkCpuUsage({
    required this.userMicroseconds,
    required this.systemMicroseconds,
    required this.wallMicroseconds,
  });

  final int userMicroseconds;
  final int systemMicroseconds;
  final int wallMicroseconds;

  int get totalMicroseconds => userMicroseconds + systemMicroseconds;

  double get utilizationPercent {
    final processors = math.max(Platform.numberOfProcessors, 1);
    return totalMicroseconds * 100 / wallMicroseconds / processors;
  }
}
