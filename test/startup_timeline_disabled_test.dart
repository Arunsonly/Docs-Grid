import 'package:flutter_test/flutter_test.dart';
import 'package:docs_grid/core/diagnostics/startup_timeline.dart';

void main() {
  test('profiling is disabled for ordinary builds', () {
    expect(StartupTimeline.enabled, isFalse);
    StartupTimeline.mark('dart_main_enter');
  });
}
