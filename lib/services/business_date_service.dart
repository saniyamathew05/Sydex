import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The business day selected before login. Transaction forms use this date as
/// their default while still allowing an individual entry to be changed.
class BusinessDateService {
  BusinessDateService._();

  static final ValueNotifier<DateTime> selectedDate = ValueNotifier(
    _day(DateTime.now()),
  );

  static DateTime _day(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static Future<void> setDate(DateTime value) async {
    final date = _day(value);
    selectedDate.value = date;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('business_date', date.toIso8601String());
  }

  static Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = DateTime.tryParse(
      preferences.getString('business_date') ?? '',
    );
    if (stored != null) selectedDate.value = _day(stored);
  }
}
