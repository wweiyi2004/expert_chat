import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../test/desktop_layout_test.dart' as desktop_layout;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final previousOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _OfflineLayoutFixture());
  tearDownAll(() => HttpOverrides.global = previousOverrides);
  desktop_layout.main();
}

// Layout interactions must not depend on live release checks or update dialogs.
class _OfflineLayoutFixture extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw UnsupportedError('Network is disabled in the layout fixture');
}
