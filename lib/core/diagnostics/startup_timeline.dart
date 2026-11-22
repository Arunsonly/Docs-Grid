import 'package:flutter/foundation.dart';

/// Diagnostic markers only: compiled out of ordinary APKs.
/// Emits timing and stage names, never user data or paths.
class StartupTimeline {
  StartupTimeline._();

  static const bool enabled =
      bool.fromEnvironment('DOCSGRID_STARTUP_PROFILE', defaultValue: false);
  static final Stopwatch _clock = Stopwatch()..start();
  static final Set<String> _seen = <String>{};
  static const Set<String> _core = <String>{
    'home_first_frame', 'home_page_ready',
    'home_summary_ready', 'home_recent_ready',
  };
  static bool _coreMarked = false;

  static void mark(String stage) {
    if (!enabled || !_seen.add(stage)) return;
    debugPrintSynchronously('DOCSGRID_STARTUP|v1|' +
        stage + '|' + _clock.elapsedMicroseconds.toString());
    // Four concurrent workstreams must all finish. No changes to rendering.
    if (!_coreMarked && _core.every(_seen.contains)) {
      _coreMarked = true;
      debugPrintSynchronously('DOCSGRID_STARTUP|v1|home_core_ready|' +
          _clock.elapsedMicroseconds.toString());
    }
  }
}
