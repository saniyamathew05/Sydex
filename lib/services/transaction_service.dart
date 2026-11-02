import 'package:flutter/foundation.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/transaction.dart';

import 'customer_service.dart';

import 'ledger_service.dart';

import 'payment_service.dart';

import 'signature_service.dart';

class TransactionService {
  static final List<PaymentTransaction> transactions = [];

  static final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

  static final SupabaseClient _supabase = Supabase.instance.client;

  static bool isLoading = false;

  static String? errorMessage;

  static Map<String, double> get customerBalances =>
      LedgerService.customerBalances;

  static Future<void> loadTransactions() async {
    // Reuse the shared customer cache when screens have already loaded it.
    // This avoids a second full customer query during every ledger refresh.
    if (CustomerService.customers.isEmpty) {
      await CustomerService.loadCustomers();
    }
    isLoading = true;

    errorMessage = null;

    dataVersion.value++;

    try {
      final response = await _supabase
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

            is_bounced

          ''')
          .order('transaction_date', ascending: false);

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

      transactions.clear();

      for (final row in response) {
        final customerId = row['customer_id'] as String;

        final customer = CustomerService.getCustomerById(customerId);
        // Inactive/deleted customers are excluded from all payment screens.
        if (customer == null) continue;

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

        transactions.add(
          PaymentTransaction(
            id: row['id'] as String,

            customerId: customerId,

            customerName: customer?.businessName ?? 'Customer',

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
          ),
        );
      }

      await loadCustomerBalances();
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isLoading = false;

      dataVersion.value++;
    }
  }

  static Future<void> loadCustomerBalances() async {
    try {
      await LedgerService.loadCustomerBalances();

      dataVersion.value++;
    } catch (error) {
      errorMessage = error.toString();

      dataVersion.value++;
    }
  }

  static double getCustomerBalance(String customerId) {
    return LedgerService.getCustomerBalance(customerId);
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
        return 'Salesman';
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
    String customerId,
  ) {
    return LedgerService.getCustomerLedger(customerId);
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
    return LedgerService.getCustomerBalance(customerId);
  }

  static List<PaymentTransaction> getCustomerTransactions(String customerId) {
    final result = transactions
        .where((transaction) => transaction.customerId == customerId)
        .toList();

    result.sort((a, b) => b.transactionDate.compareTo(a.transactionDate));

    return result;
  }

  static double getCollectedToday() {
    final now = DateTime.now();

    return transactions
        .where(
          (transaction) {
            final localDate = transaction.transactionDate.toLocal();
            return localDate.year == now.year &&
                localDate.month == now.month &&
                localDate.day == now.day;
          },
        )
        .fold(0.0, (sum, transaction) => sum + transaction.amountReceived);
  }

  static double getTotalCollectedToday() {
    return getCollectedToday();
  }

  static int getPaymentsToday() {
    final now = DateTime.now();

    return transactions
        .where(
          (transaction) {
            final localDate = transaction.transactionDate.toLocal();
            return localDate.year == now.year &&
                localDate.month == now.month &&
                localDate.day == now.day;
          },
        )
        .length;
  }

  static double getTotalMoneyToReceive(List<dynamic> customers) {
    double total = 0;

    for (final customer in customers) {
      total += LedgerService.getCustomerBalance(customer.id);
    }

    return total;
  }
}
