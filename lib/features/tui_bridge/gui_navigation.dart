import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/work_changes.dart';

class TuiGuiChangeRequest {
  TuiGuiChangeRequest(this.file);
  final WorkFileChange file;
}

final tuiGuiNavigationProvider =
    NotifierProvider<TuiGuiNavigation, TuiGuiChangeRequest?>(
      TuiGuiNavigation.new,
    );

class TuiGuiNavigation extends Notifier<TuiGuiChangeRequest?> {
  @override
  TuiGuiChangeRequest? build() => null;
  void openChange(WorkFileChange file) => state = TuiGuiChangeRequest(file);
}
