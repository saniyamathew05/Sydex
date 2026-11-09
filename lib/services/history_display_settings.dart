import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HistoryDisplaySettings {
  HistoryDisplaySettings._();

  static const _key = 'sydex_recent_payment_limit';
  static const unlimited = 0;
  static final ValueNotifier<int> limit = ValueNotifier<int>(unlimited);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    limit.value = prefs.getInt(_key) ?? unlimited;
  }

  static Future<void> setLimit(int value) async {
    final normalized = value < 0 ? unlimited : value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, normalized);
    limit.value = normalized;
  }
}
