import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owner-controlled display preferences. These affect presentation only and
/// never change or delete business records.
class OwnerDisplaySettings {
  OwnerDisplaySettings._();

  static const _recentPayments = 'sydex_owner_show_recent_payments';
  static const _balances = 'sydex_owner_show_balances';
  static const _quickActions = 'sydex_owner_show_quick_actions';

  static final showRecentPayments = ValueNotifier(true);
  static final showBalances = ValueNotifier(true);
  static final showQuickActions = ValueNotifier(true);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    showRecentPayments.value = prefs.getBool(_recentPayments) ?? true;
    showBalances.value = prefs.getBool(_balances) ?? true;
    showQuickActions.value = prefs.getBool(_quickActions) ?? true;
  }

  static Future<void> setRecentPayments(bool value) async => _set(_recentPayments, value, showRecentPayments);
  static Future<void> setBalances(bool value) async => _set(_balances, value, showBalances);
  static Future<void> setQuickActions(bool value) async => _set(_quickActions, value, showQuickActions);

  static Future<void> _set(String key, bool value, ValueNotifier<bool> target) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    target.value = value;
  }
}
