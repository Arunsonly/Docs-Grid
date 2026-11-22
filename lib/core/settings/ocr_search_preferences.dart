import 'package:shared_preferences/shared_preferences.dart';

/// The durable opt-in only controls whether OCR mode can be offered.
/// It never activates OCR mode or starts indexing by itself.
class OcrSearchPreferences {
  OcrSearchPreferences._();

  static const key = 'docsgrid_enable_ocr_search_v1';

  static Future<bool> isEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(key) ?? false;
  }

  static Future<void> setEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(key, enabled)) {
      throw StateError('Could not save OCR search preference.');
    }
  }
}
