import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Remote counts remain unknown until a real successful host response.
final remoteAutomationCountsProvider =
    NotifierProvider<RemoteAutomationCounts, Map<String, int?>>(
      RemoteAutomationCounts.new,
    );

class RemoteAutomationCounts extends Notifier<Map<String, int?>> {
  @override
  Map<String, int?> build() => {};
  void reconcile(Iterable<String> hosts) => state = hosts.isEmpty
      ? {'@none': 0}
      : {for (final host in hosts) host: null};
  void report(String host, int? enabled) => state = {...state, host: enabled};
}
