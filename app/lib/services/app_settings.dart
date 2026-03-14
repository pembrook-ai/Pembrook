/// AppSettings — lightweight ChangeNotifier for UI preferences.
///
/// Currently tracks:
///   - fontScale: text scale factor applied globally via MediaQuery.
///
/// Values are persisted to SharedPreferences so they survive app restarts.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings extends ChangeNotifier {
  static const String _keyFontScale = 'fontScale';

  double _fontScale = 1.0;

  /// Text scale factor in the range [0.8, 1.6].  1.0 = system default.
  double get fontScale => _fontScale;

  AppSettings() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getDouble(_keyFontScale);
    if (stored != null) {
      _fontScale = stored.clamp(0.8, 1.6);
      notifyListeners();
    }
  }

  /// Update the font scale and persist it.
  Future<void> setFontScale(double scale) async {
    _fontScale = scale.clamp(0.8, 1.6);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontScale, _fontScale);
  }
}
