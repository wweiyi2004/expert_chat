import 'package:dio/dio.dart';
import 'dart:convert';
import '../../remote/remote_tool_proxy.dart';
import 'math_spec.dart';
import 'math_worker_stub.dart'
    if (dart.library.io) 'math_worker_io.dart'
    as worker;

/// Lazy optional local mathematics. This executes a trusted bundled interpreter,
/// never model supplied source, shell commands, or SymPy's eval-based parser.
class MathToolkit {
  MathToolkit({this.pythonExecutable = 'python'});
  final String pythonExecutable;
  final _remote = RemoteToolProxy(snapshotPair: true);
  Future<Map<String, dynamic>> installManaged({
    CancelToken? cancelToken,
    void Function(String)? onStage,
  }) => worker.installManagedMath(
    pythonExecutable: pythonExecutable,
    cancelToken: cancelToken,
    onStage: onStage,
  );
  static const spec = mathToolSpec;

  Future<Map<String, dynamic>> diagnose({CancelToken? cancelToken}) =>
      execute({'operation': 'diagnose'}, cancelToken: cancelToken);
  Future<Map<String, dynamic>> execute(
    Map<String, dynamic> arguments, {
    CancelToken? cancelToken,
  }) async {
    if (worker.requiresRemoteMath) {
      final result = await _remote.executeMath(
        arguments,
        cancelToken: cancelToken,
      );
      return Map<String, dynamic>.from(jsonDecode(result) as Map);
    }
    return worker.executeMath(
      arguments,
      pythonExecutable: pythonExecutable,
      cancelToken: cancelToken,
    );
  }
}
