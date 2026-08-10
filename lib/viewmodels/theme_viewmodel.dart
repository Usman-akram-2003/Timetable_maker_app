import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeViewModel extends ChangeNotifier {
  static const _key = 'is_dark_mode';

  final SharedPreferences _prefs;
  bool _isDark;

  ThemeViewModel(this._prefs)
      : _isDark = _prefs.getBool(_key) ?? false; // default: light

  bool get isDark => _isDark;
  ThemeMode get themeMode => _isDark ? ThemeMode.dark : ThemeMode.light;

  void toggle() {
    _isDark = !_isDark;
    _prefs.setBool(_key, _isDark);
    notifyListeners();
  }
}
