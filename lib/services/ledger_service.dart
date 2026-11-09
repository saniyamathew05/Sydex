import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_pagination.dart';

class LedgerService {
  static final SupabaseClient _supabase = Supabase.instance.client;

  static bool isLoading = false;
  static String? errorMessage;
  static String? _cacheUserId;

  static final Map<String, double> customerBalances = {};

  static final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

  // ------------------------------------------------------------
  // LOAD CUSTOMER BALANCES
  // ------------------------------------------------------------

  static Future<void> loadCustomerBalances() async {
    errorMessage = null;

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (_cacheUserId != userId) {
        customerBalances.clear();
        _cacheUserId = userId;
      }
      if (userId == null) {
        throw StateError('No logged-in user found while loading balances.');
      }

      final response = await _supabase.rpc('get_customer_balances');

      // Publish the refreshed snapshot only after the RPC has completed and
      // parsed successfully. If a refresh fails, screens keep the last known
      // balances instead of briefly (or permanently) rendering every customer
      // as owing zero.
      final refreshedBalances = <String, double>{};

      for (final row in response) {
        final customerId = row['customer_id'] as String;

        final balance = (row['balance'] as num).toDouble();

        refreshedBalances[customerId] = _roundCurrency(balance);
      }

      customerBalances
        ..clear()
        ..addAll(refreshedBalances);

      dataVersion.value++;
    } catch (error) {
      errorMessage = error.toString();
      dataVersion.value++;
      rethrow;
    }
  }

  static double getCustomerBalance(String customerId) {
    return customerBalances[customerId] ?? 0;
  }

  // ------------------------------------------------------------
  // CUSTOMER LEDGER
  // ------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> getCustomerLedger(
    String customerId, {
    double openingBalance = 0,
  }) async {
    errorMessage = null;

    try {
      final response = await SupabasePagination.loadAll(
        (from, to) => _supabase
            .from('ledger_entries')
            .select('*, profiles(name)')
            .eq('customer_id', customerId)
            .order('id')
            .range(from, to),
      );

      final entries = List<Map<String, dynamic>>.from(
        response.map((entry) => Map<String, dynamic>.from(entry)),
      );

      final hiddenRows = await _supabase
          .from('payments')
          .select('id')
          .eq('customer_id', customerId)
          .eq('hidden_from_ledger', true);
      final hiddenIds = (hiddenRows as List)
          .map((row) => row['id']?.toString())
          .whereType<String>()
          .toSet();
      entries.removeWhere(
        (entry) => entry['entry_type']?.toString() == 'payment' &&
            hiddenIds.contains(entry['id']?.toString()),
      );

      // Keep historical payments visible even when an older deployment has a
      // payment row but its matching ledger row was not exposed by RLS.
      final knownIds = entries
          .map((entry) => entry['id']?.toString())
          .whereType<String>()
          .toSet();
      try {
        final paymentRows = await _supabase
            .from('payments')
            .select('''
            id, customer_id, user_id, amount, discount, amount_received,
            previous_balance, remaining_balance, transaction_date, created_at,
            notes, signature_path, payment_method, payment_method_note,
            is_bounced, profiles(name)
          ''')
            .eq('customer_id', customerId)
            .eq('hidden_from_ledger', false)
            .order('created_at');
        for (final row in paymentRows) {
          final id = row['id']?.toString();
          if (id == null || knownIds.contains(id)) continue;
          entries.add({
            ...Map<String, dynamic>.from(row),
            'entry_type': 'payment',
          });
          knownIds.add(id);
        }
      } catch (_) {
        // The ledger itself remains usable if the compatibility query is not
        // available on an older schema.
      }
      entries.sort(_compareLedgerChronology);

      var balance = openingBalance;
      for (final entry in entries) {
        final type = entry['entry_type']?.toString().toLowerCase();
        final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
        entry['balance_before'] = _roundCurrency(balance);
        if (type == 'purchase' || type == 'sale' || type == 'bounced_check') {
          balance += amount;
        } else if (type == 'payment' ||
            type == 'return' ||
            type == 'sales_return') {
          balance -= amount;
        }
        balance = _roundCurrency(balance);
        entry['balance_after'] = balance;
      }

      entries.sort((a, b) => _compareLedgerChronology(b, a));
      return entries;
    } catch (error) {
      errorMessage = error.toString();
      return [];
    }
  }

  static int _compareLedgerChronology(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    DateTime dateOf(Map<String, dynamic> entry, String key) =>
        DateTime.tryParse(entry[key]?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    final transactionDate = dateOf(
      a,
      'transaction_date',
    ).compareTo(dateOf(b, 'transaction_date'));
    if (transactionDate != 0) return transactionDate;

    // The transaction date is the business event date. For entries on the
    // same date, use the recorded timestamp to preserve the order in which
    // the owner or salesman entered them. This also handles legacy rows that
    // have a missing created_at value without moving them ahead of newer
    // transactions.
    final createdAt = dateOf(
      a,
      'created_at',
    ).compareTo(dateOf(b, 'created_at'));
    if (createdAt != 0) return createdAt;

    return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
  }

  static double _roundCurrency(double value) =>
      (value * 100).roundToDouble() / 100;

  // ------------------------------------------------------------
  // CURRENT BALANCE FROM LEDGER
  // ------------------------------------------------------------

  static Future<double> getCurrentBalanceFromLedger({
    required String customerId,
    required double openingBalance,
  }) async {
    errorMessage = null;

    try {
      final response = await _supabase.rpc('get_customer_balances');

      for (final row in response) {
        if (row['customer_id'] == customerId) {
          return _roundCurrency((row['balance'] as num).toDouble());
        }
      }
    } catch (error) {
      errorMessage = error.toString();
    }

    // Older deployments or role-scoped RPC results can omit a customer. Use
    // the customer's visible ledger to calculate the balance before falling
    // back to opening balance; returning opening balance directly made
    // customers with recorded sales appear to owe zero.
    final entries = await getCustomerLedger(
      customerId,
      openingBalance: openingBalance,
    );
    if (entries.isNotEmpty) {
      final balance = (entries.first['balance_after'] as num?)?.toDouble();
      if (balance != null) return _roundCurrency(balance);
    }
    return _roundCurrency(openingBalance);
  }

  // ------------------------------------------------------------
  // SIGNATURE DOWNLOAD
  // ------------------------------------------------------------

  static Future<Uint8List?> downloadSignature(String? signaturePath) async {
    if (signaturePath == null || signaturePath.isEmpty) {
      return null;
    }

    try {
      final bytes = await _supabase.storage
          .from('payment-signatures')
          .download(signaturePath);

      return bytes;
    } catch (error) {
      errorMessage = error.toString();
      return null;
    }
  }
}
