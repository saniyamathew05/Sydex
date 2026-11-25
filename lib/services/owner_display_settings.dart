import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One on/off choice about what a screen shows. These affect presentation
/// only: they never change or delete business records, and hiding something
/// is not a permission check.
class DisplayOption {
  const DisplayOption(this.key, this.group, this.title, this.subtitle);

  final String key;
  final String group;
  final String title;
  final String subtitle;
}

/// What the owner sees. Saved on this device.
class OwnerDisplaySettings {
  OwnerDisplaySettings._();

  static const balances = 'balances';
  static const stats = 'stats';
  static const quickActions = 'quick_actions';
  static const paymentsChart = 'payments_chart';
  static const salesmanActivity = 'salesman_activity';
  static const recentPayments = 'recent_payments';
  static const locationDue = 'location_due';
  static const enteredBy = 'ledger_entered_by';
  static const enteredByRole = 'ledger_entered_by_role';
  static const notes = 'ledger_notes';
  static const refused = 'ledger_refused';
  static const returns = 'ledger_returns';
  static const ledgerBalance = 'ledger_balance';

  static const options = <DisplayOption>[
    DisplayOption(balances, 'Home', 'Balances', 'Outstanding and due amounts'),
    DisplayOption(stats, 'Home', 'Summary tiles', 'Customers, sales, payments'),
    DisplayOption(quickActions, 'Home', 'Quick actions', 'Shortcut buttons'),
    DisplayOption(
      paymentsChart,
      'Home',
      'Payments overview',
      'Daily collections chart',
    ),
    DisplayOption(
      salesmanActivity,
      'Home',
      'Salesman activity',
      'Today’s visits by salesman',
    ),
    DisplayOption(
      recentPayments,
      'Home',
      'Recent payments',
      'Latest payments received',
    ),
    DisplayOption(
      locationDue,
      'Home',
      'Location-wise due',
      'Amounts due by area',
    ),
    DisplayOption(
      enteredBy,
      'Payment ledger',
      'Entered by',
      'Who recorded each payment',
    ),
    DisplayOption(
      enteredByRole,
      'Payment ledger',
      'Role with the name',
      'Owner or Marketing Executive',
    ),
    DisplayOption(notes, 'Payment ledger', 'Notes', 'Notes on each payment'),
    DisplayOption(
      refused,
      'Payment ledger',
      'Refused payments',
      'Refusals listed with payments',
    ),
    DisplayOption(
      returns,
      'Payment ledger',
      'Sales returns',
      'Returns listed with payments',
    ),
    DisplayOption(
      ledgerBalance,
      'Payment ledger',
      'Pending balance',
      'What each customer owes now',
    ),
  ];

  static String _prefKey(String key) => 'sydex_owner_show_$key';

  static final ValueNotifier<Map<String, bool>> values = ValueNotifier({});

  static bool show(String key) => values.value[key] ?? true;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    values.value = {
      for (final option in options)
        option.key: prefs.getBool(_prefKey(option.key)) ?? true,
    };
  }

  static Future<void> set(String key, bool value) async {
    values.value = {...values.value, key: value};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey(key), value);
  }

  static Future<void> reset() async {
    for (final option in options) {
      await set(option.key, true);
    }
  }
}

/// What salesmen see. The owner chooses, and it applies to every salesman in
/// the company.
class SalesmanDisplaySettings {
  SalesmanDisplaySettings._();

  static const routeBalances = 'route_balances';
  static const phone = 'phone';
  static const collected = 'collected';
  static const recentPayments = 'recent_payments';
  static const qr = 'qr';
  static const map = 'map';
  static const teamPayments = 'team_payments';
  static const refused = 'refused';

  static const options = <DisplayOption>[
    DisplayOption(
      collected,
      'Home',
      'Collection totals',
      'Collected today and left to collect',
    ),
    DisplayOption(
      recentPayments,
      'Home',
      'Recent payments',
      'Latest payments they recorded',
    ),
    DisplayOption(
      qr,
      'Home',
      'Receive payment by QR',
      'Payment QR shortcut on the home page',
    ),
    DisplayOption(
      routeBalances,
      'Route',
      'Balances on the route list',
      'Amount due beside each customer',
    ),
    DisplayOption(
      phone,
      'Route',
      'Customer phone numbers',
      'Phone number on the customer page',
    ),
    DisplayOption(map, 'Route', 'Route map', 'Map tab with today’s stops'),
    DisplayOption(
      teamPayments,
      'Payments',
      'Team payments',
      'Payments recorded by other salesmen',
    ),
    DisplayOption(
      refused,
      'Payments',
      'Refused payments',
      'Refusals listed with payments',
    ),
  ];

  static const _table = 'company_display_settings';
  static const _cacheKey = 'sydex_salesman_display';

  static final ValueNotifier<Map<String, bool>> values = ValueNotifier({});

  static bool show(String key) => values.value[key] ?? true;

  static Map<String, bool> _clean(Object? raw) => {
    if (raw is Map)
      for (final option in options)
        if (raw[option.key] is bool) option.key: raw[option.key] as bool,
  };

  /// Loads the company's choices. If they cannot be read, the last known
  /// choices are kept, or everything is shown.
  static Future<void> load() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = '$_cacheKey.${user.id}';
    try {
      final row = await Supabase.instance.client
          .from(_table)
          .select('salesman')
          .maybeSingle();
      values.value = _clean(row?['salesman']);
      await prefs.setString(cacheKey, jsonEncode(values.value));
    } catch (error) {
      debugPrint('Could not load salesman display options: $error');
      try {
        values.value = _clean(jsonDecode(prefs.getString(cacheKey) ?? '{}'));
      } catch (_) {
        values.value = {};
      }
    }
  }

  static Future<void> set(String key, bool value) =>
      _save({...values.value, key: value});

  static Future<void> reset() => _save({});

  /// Shows the change at once and puts it back if it could not be saved.
  static Future<void> _save(Map<String, bool> next) async {
    final before = values.value;
    values.value = next;
    try {
      final companyId = await Supabase.instance.client.rpc(
        'current_company_id',
      );
      await Supabase.instance.client.from(_table).upsert({
        'company_id': companyId,
        'salesman': next,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      values.value = before;
      rethrow;
    }
  }
}
