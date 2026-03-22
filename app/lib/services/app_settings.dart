/// AppSettings — lightweight ChangeNotifier for UI preferences.
///
/// Tracks:
///   - fontScale: text scale factor applied globally via MediaQuery.
///   - themeMode: light / dark / system (default: system).
///
/// Values are persisted to SharedPreferences so they survive app restarts.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings extends ChangeNotifier {
  static const String _keyFontScale = 'fontScale';
  static const String _keyThemeMode = 'themeMode';

  double _fontScale = 1.0;
  ThemeMode _themeMode = ThemeMode.system;

  /// Text scale factor in the range [0.8, 1.6].  1.0 = system default.
  double get fontScale => _fontScale;

  /// Current theme mode (light / dark / system).
  ThemeMode get themeMode => _themeMode;

  AppSettings() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final storedScale = prefs.getDouble(_keyFontScale);
    if (storedScale != null) {
      _fontScale = storedScale.clamp(0.8, 1.6);
    }
    final storedTheme = prefs.getString(_keyThemeMode);
    if (storedTheme != null) {
      _themeMode = _themeModeFromString(storedTheme);
    }
    notifyListeners();
  }

  /// Update the font scale and persist it.
  Future<void> setFontScale(double scale) async {
    _fontScale = scale.clamp(0.8, 1.6);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontScale, _fontScale);
  }

  /// Update the theme mode and persist it.
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeMode, mode.name);
  }

  static ThemeMode _themeModeFromString(String s) {
    switch (s) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
