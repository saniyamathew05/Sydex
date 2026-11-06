import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the selected appearance and supports following the device theme.
///
/// ThemeMode.system means Flutter follows the operating system's brightness
/// automatically. Keep this notifier as the single source of truth for the app.
class ThemeController {
  ThemeController._();

  static const String _preferenceKey = 'ledgerpro_theme_mode';
  static const String _accentPreferenceKey = 'ledgerpro_accent_color';

  static const Map<String, Color> accentChoices = <String, Color>{
    'Forest': Color(0xFF075C42),
    'Emerald': Color(0xFF087553),
    'Teal': Color(0xFF0B6E69),
    'Ocean': Color(0xFF1D5F82),
    'Plum': Color(0xFF6B456D),
  };

  // Use the device setting for a fresh install unless the user has explicitly
  // selected Light or Dark mode before.
  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.system);
  static final ValueNotifier<Color> accentColor =
      ValueNotifier<Color>(accentChoices['Forest']!);

  static Future<void> loadTheme() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(_preferenceKey);

    themeMode.value = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      // Do not force Light mode on first launch. Follow the device instead.
      _ => ThemeMode.system,
    };
    final savedAccent = preferences.getString(_accentPreferenceKey);
    accentColor.value = accentChoices[savedAccent] ?? accentChoices['Forest']!;
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };

    // Persist the choice and then notify the MaterialApp to rebuild.
    await preferences.setString(_preferenceKey, saved);
    themeMode.value = mode;
  }

  static Future<void> setAccent(String name) async {
    final color = accentChoices[name];
    if (color == null) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_accentPreferenceKey, name);
    accentColor.value = color;
  }

  static String get accentName => accentChoices.entries
      .firstWhere(
        (entry) => entry.value.value == accentColor.value.value,
        orElse: () => const MapEntry('Forest', Color(0xFF075C42)),
      )
      .key;

  /// Compatibility method used by the Settings screen.
  static Future<void> setTheme(ThemeMode mode) => setThemeMode(mode);

  static Future<void> toggleTheme() async {
    // A manual toggle switches explicitly between Light and Dark.
    // Selecting "Use device setting" in Settings returns to system mode.
    await setThemeMode(
      themeMode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
    );
  }
}
