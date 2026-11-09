import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The business day selected before login. Transaction forms use this date as
/// their default while still allowing an individual entry to be changed.
class BusinessDateService {
  BusinessDateService._();

  static final ValueNotifier<DateTime> selectedDate = ValueNotifier(
    _day(DateTime.now()),
  );
  static final ValueNotifier<bool> isManual = ValueNotifier(false);

  static DateTime _day(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static Future<void> setDate(DateTime value, {bool manual = true}) async {
    final date = _day(value);
    selectedDate.value = date;
    isManual.value = manual;
    final preferences = await SharedPreferences.getInstance();
    if (manual) {
      await preferences.setString('business_date', date.toIso8601String());
    } else {
      await preferences.remove('business_date');
    }
  }

  static Future<void> load() async {
    // A date selected in a previous process must never silently become the
    // default for a new session. The current device-local date is automatic.
    isManual.value = false;
    selectedDate.value = _day(DateTime.now());
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('business_date');
  }

  static Future<void> useToday() => setDate(DateTime.now(), manual: false);

  static void refreshAutomaticDate() {
    if (!isManual.value) {
      final today = _day(DateTime.now());
      if (selectedDate.value != today) selectedDate.value = today;
    }
  }
}
