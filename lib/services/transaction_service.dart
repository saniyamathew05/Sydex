import 'package:flutter/foundation.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/transaction.dart';

import 'customer_service.dart';

import 'ledger_service.dart';

import 'payment_service.dart';

import 'signature_service.dart';
import 'supabase_pagination.dart';

class TransactionService {
  static final List<PaymentTransaction> transactions = [];

  static final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

  static final SupabaseClient _supabase = Supabase.instance.client;

  static bool isLoading = false;

  static String? errorMessage;
  static String? _cacheUserId;

  static Map<String, double> get customerBalances =>
      LedgerService.customerBalances;

  static void _prepareCacheForCurrentUser() {
    final userId = _supabase.auth.currentUser?.id;
    if (_cacheUserId == userId) return;

    transactions.clear();
    _cacheUserId = userId;
  }

  static Future<void> loadTransactions() async {
    _prepareCacheForCurrentUser();

    // Reuse the shared customer cache when screens have already loaded it.
    // This avoids a second full customer query during every ledger refresh.
    if (CustomerService.customers.isEmpty) {
      await CustomerService.loadCustomers();
    }
    isLoading = true;

    errorMessage = null;

    dataVersion.value++;

    try {
      final response = await SupabasePagination.loadAll(
        (from, to) => _supabase
            .from('payments')
            .select('''

            id,

            customer_id,

            user_id,

            amount,

            discount,

            amount_received,

            previous_balance,

            remaining_balance,

            transaction_date,
            created_at,

            notes,

            signature_path,

            payment_method,

            payment_method_note,

            is_bounced,
            customers (business_name)

          ''')
            .order('transaction_date', ascending: false)
            .order('id', ascending: false)
            .range(from, to),
      );

      final userIds = response
          .map((row) => row['user_id']?.toString())
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final profilesById = <String, Map<String, dynamic>>{};
      if (userIds.isNotEmpty) {
        try {
          final profiles = await _supabase
              .from('profiles')
              .select('id, name, role')
              .inFilter('id', userIds);
          for (final profile in profiles) {
            profilesById[profile['id'].toString()] = Map<String, dynamic>.from(
              profile,
            );
          }
        } catch (error) {
          debugPrint('Could not load payment entry profiles: $error');
        }
      }

      final refreshedTransactions = <PaymentTransaction>[];
      for (final row in response) {
        final customerId = row['customer_id'] as String;

        final customer = CustomerService.getCustomerById(customerId);
        final linkedCustomer = row['customers'];
        final historyName = linkedCustomer is Map
            ? linkedCustomer['business_name']?.toString().trim()
            : null;

        final userId = row['user_id']?.toString();
        final profile = userId == null ? null : profilesById[userId];
        final role = _paymentEntryRole(profile?['role']?.toString());
        final name = profile?['name']?.toString().trim();
        final receivedBy = name == null || name.isEmpty
            ? role
            : '$role • $name';

        final amount = (row['amount'] as num).toDouble();

        final discount = (row['discount'] as num?)?.toDouble() ?? 0;

        final amountReceived =
            (row['amount_received'] as num?)?.toDouble() ?? (amount - discount);

        refreshedTransactions.add(
          PaymentTransaction(
            id: row['id'] as String,

            customerId: customerId,

            customerName:
                customer?.businessName ??
                (historyName == null || historyName.isEmpty
                    ? 'Customer'
                    : historyName),

            amount: amount,

            discount: discount,

            amountReceived: amountReceived,

            previousBalance: (row['previous_balance'] as num).toDouble(),

            remainingBalance: (row['remaining_balance'] as num).toDouble(),

            transactionDate: DateTime.parse(row['transaction_date'] as String),

            createdAt: row['created_at'] == null
                ? null
                : DateTime.parse(row['created_at'] as String),

            notes: (row['notes'] as String?) ?? '',

            signature: Uint8List(0),

            signaturePath: row['signature_path'] as String?,

            receivedBy: receivedBy,

            paymentMethod: row['payment_method']?.toString() ?? 'cash',

            paymentMethodNote: row['payment_method_note']?.toString() ?? '',

            isBounced: row['is_bounced'] == true,

            transactionType: 'payment_received',
          ),
        );
      }
      refreshedTransactions.sort((a, b) {
        final dateOrder = b.transactionDate.compareTo(a.transactionDate);
        if (dateOrder != 0) return dateOrder;
        return (b.createdAt ?? b.transactionDate).compareTo(
          a.createdAt ?? a.transactionDate,
        );
      });

      transactions
        ..clear()
        ..addAll(refreshedTransactions);

      await loadCustomerBalances();
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isLoading = false;

      dataVersion.value++;
    }
  }

  static Future<void> loadCustomerBalances() async {
    _prepareCacheForCurrentUser();

    if (CustomerService.customers.isEmpty &&
        _supabase.auth.currentUser != null) {
      await CustomerService.loadCustomers();
    }

    var rpcLoaded = false;
    try {
      await LedgerService.loadCustomerBalances();
      rpcLoaded = true;
    } catch (error) {
      // Continue to the company-visible ledger fallback below. A failed RPC
      // must not make missing customer balances look like zero.
      errorMessage = error.toString();
    }

    // The RPC normally returns every active customer. If an older or
    // partially migrated database omits a row, reconstruct only the
    // missing customers from their company-visible ledger entries instead
    // of silently showing zero. RLS still scopes this read to the signed-in
    // company's data.
    final missingCustomers = CustomerService.customers
        .where(
          (customer) =>
              !rpcLoaded || !customerBalances.containsKey(customer.id),
        )
        .toList(growable: false);
    if (missingCustomers.isNotEmpty) {
      try {
        final entries = await SupabasePagination.loadAll(
          (from, to) => _supabase
              .from('ledger_entries')
              .select('id, customer_id, entry_type, amount')
              .inFilter(
                'customer_id',
                missingCustomers.map((customer) => customer.id).toList(),
              )
              .order('id')
              .range(from, to),
        );
        final balanceByCustomer = <String, double>{
          for (final customer in missingCustomers)
            customer.id: customer.openingBalance,
        };
        for (final entry in entries) {
          final customerId = entry['customer_id']?.toString();
          if (customerId == null ||
              !balanceByCustomer.containsKey(customerId)) {
            continue;
          }
          final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
          final type = entry['entry_type']?.toString().toLowerCase();
          if (type == 'purchase' || type == 'sale' || type == 'bounced_check') {
            balanceByCustomer[customerId] =
                (balanceByCustomer[customerId] ?? 0) + amount;
          } else if (type == 'payment' ||
              type == 'return' ||
              type == 'sales_return') {
            balanceByCustomer[customerId] =
                (balanceByCustomer[customerId] ?? 0) - amount;
          }
        }
        for (final entry in balanceByCustomer.entries) {
          customerBalances[entry.key] =
              (entry.value * 100).roundToDouble() / 100;
        }
        errorMessage = null;
      } catch (fallbackError) {
        errorMessage = fallbackError.toString();
        debugPrint(
          'Could not reconstruct missing customer balances: $fallbackError',
        );
        for (final customer in missingCustomers) {
          customerBalances.putIfAbsent(
            customer.id,
            () => customer.openingBalance,
          );
        }
      }
    }

    dataVersion.value++;
  }

  static double getCustomerBalance(String customerId) {
    if (customerBalances.containsKey(customerId)) {
      return LedgerService.getCustomerBalance(customerId);
    }
    return CustomerService.getCustomerById(customerId)?.openingBalance ?? 0;
  }

  static Future<Uint8List?> downloadSignature(String? signaturePath) async {
    return SignatureService.downloadSignature(signaturePath);
  }

  static Future<bool> addTransactionWithSignature(
    PaymentTransaction transaction,

    String? signaturePath,
  ) async {
    errorMessage = null;

    if (signaturePath == null || signaturePath.isEmpty) {
      errorMessage = 'Signature path is missing.';

      dataVersion.value++;

      return false;
    }

    try {
      final savedTransaction = await PaymentService.recordPayment(
        customerId: transaction.customerId,

        customerName: transaction.customerName,

        amount: transaction.amount,

        discount: transaction.discount,

        notes: transaction.notes,

        signature: transaction.signature,

        signaturePath: signaturePath,

        transactionDate: transaction.transactionDate,

        paymentMethod: transaction.paymentMethod,

        paymentMethodNote: transaction.paymentMethodNote,
      );

      if (savedTransaction == null) {
        errorMessage = 'Payment could not be recorded.';

        dataVersion.value++;

        return false;
      }

      final currentUser = _supabase.auth.currentUser;

      final currentProfile = currentUser == null
          ? null
          : await _supabase
                .from('profiles')
                .select('name, role')
                .eq('id', currentUser.id)
                .maybeSingle();

      final role = _paymentEntryRole(currentProfile?['role']?.toString());
      final name = currentProfile?['name']?.toString().trim();
      final receivedBy = name == null || name.isEmpty ? role : '$role • $name';

      transactions.insert(
        0,

        PaymentTransaction(
          id: savedTransaction.id,

          customerId: savedTransaction.customerId,

          customerName: savedTransaction.customerName,

          amount: savedTransaction.amount,

          discount: savedTransaction.discount,

          amountReceived: savedTransaction.amountReceived,

          previousBalance: savedTransaction.previousBalance,

          remainingBalance: savedTransaction.remainingBalance,

          transactionDate: savedTransaction.transactionDate,

          createdAt: savedTransaction.createdAt,

          notes: savedTransaction.notes,

          signature: savedTransaction.signature,

          signaturePath: savedTransaction.signaturePath,

          receivedBy: receivedBy,

          paymentMethod: savedTransaction.paymentMethod,

          paymentMethodNote: savedTransaction.paymentMethodNote,

          isBounced: savedTransaction.isBounced,

          transactionType: savedTransaction.transactionType,
        ),
      );

      await loadCustomerBalances();

      dataVersion.value++;

      return true;
    } catch (error) {
      errorMessage = error.toString();

      dataVersion.value++;

      return false;
    }
  }

  static String _paymentEntryRole(String? role) {
    switch (role?.trim().toLowerCase()) {
      case 'owner':
        return 'Owner';
      case 'salesman':
      case 'salesperson':
        return 'Marketing Executive';
      default:
        return 'Unknown';
    }
  }

  /// Updates editable fields for an existing received payment.
  /// The database remains the source of truth for balances; reload the ledger
  /// after the update so summary cards and customer balances stay in sync.
  static Future<bool> updatePayment({
    required String paymentId,
    required double amount,
    required double discount,
    required String notes,
    required String paymentMethod,
    required String paymentMethodNote,
    required DateTime transactionDate,
  }) async {
    errorMessage = null;
    if (amount <= 0 || discount < 0 || discount >= amount) {
      errorMessage =
          'Amount must be positive and discount must be less than amount.';
      return false;
    }
    try {
      final updated = await _supabase.rpc(
        'update_payment',
        params: {
          'p_payment_id': paymentId,
          'p_amount': amount,
          'p_discount': discount,
          'p_notes': notes.trim().isEmpty ? null : notes.trim(),
          'p_payment_method': paymentMethod,
          'p_payment_method_note': paymentMethodNote.trim().isEmpty
              ? null
              : paymentMethodNote.trim(),
          'p_transaction_date': transactionDate.toUtc().toIso8601String(),
        },
      );
      if (updated != true) {
        errorMessage = 'The payment was not updated.';
        return false;
      }
      await loadTransactions();
      await loadCustomerBalances();
      return true;
    } catch (error) {
      errorMessage = error.toString();
      dataVersion.value++;
      return false;
    }
  }

  static Future<bool> deletePayment(String paymentId) async {
    errorMessage = null;

    try {
      final success = await PaymentService.deletePayment(paymentId);

      if (success) {
        transactions.removeWhere((transaction) => transaction.id == paymentId);

        await loadCustomerBalances();

        dataVersion.value++;
      }

      return success;
    } catch (error) {
      errorMessage = error.toString();

      dataVersion.value++;

      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> getCustomerLedger(
    String customerId, {
    double openingBalance = 0,
  }) {
    return LedgerService.getCustomerLedger(
      customerId,
      openingBalance: openingBalance,
    );
  }

  static Future<double> getCurrentBalanceFromLedger({
    required String customerId,

    required double openingBalance,
  }) {
    return LedgerService.getCurrentBalanceFromLedger(
      customerId: customerId,

      openingBalance: openingBalance,
    );
  }

  static double getCurrentBalance({
    required String customerId,

    required double openingBalance,
  }) {
    if (customerBalances.containsKey(customerId)) {
      return LedgerService.getCustomerBalance(customerId);
    }
    return openingBalance;
  }

  static List<PaymentTransaction> getCustomerTransactions(String customerId) {
    final result = transactions
        .where((transaction) => transaction.customerId == customerId)
        .toList();

    result.sort((a, b) {
      final dateOrder = b.transactionDate.compareTo(a.transactionDate);
      if (dateOrder != 0) return dateOrder;
      return (b.createdAt ?? b.transactionDate).compareTo(
        a.createdAt ?? a.transactionDate,
      );
    });

    return result;
  }

  static double getCollectedToday() {
    final now = DateTime.now();

    return transactions
        .where((transaction) {
          final localDate = transaction.transactionDate.toLocal();
          return transaction.transactionType == 'payment_received' &&
              !transaction.isBounced &&
              localDate.year == now.year &&
              localDate.month == now.month &&
              localDate.day == now.day;
        })
        .fold(
          0.0,
          (sum, transaction) => sum + transaction.actualAmountReceived,
        );
  }

  static double getTotalCollectedToday() {
    return getCollectedToday();
  }

  static int getPaymentsToday() {
    final now = DateTime.now();

    return transactions.where((transaction) {
      final localDate = transaction.transactionDate.toLocal();
      return transaction.transactionType == 'payment_received' &&
          !transaction.isBounced &&
          localDate.year == now.year &&
          localDate.month == now.month &&
          localDate.day == now.day;
    }).length;
  }

  static double getTotalMoneyToReceive(List<dynamic> customers) {
    double total = 0;

    for (final customer in customers) {
      final balance = LedgerService.getCustomerBalance(customer.id);
      if (balance > 0) total += balance;
    }

    return total;
  }
}
