import 'package:supabase_flutter/supabase_flutter.dart';

/// A similarity warning only. Financial writes remain controlled by the
/// existing server RPCs and a warning never changes a transaction by itself.
class DuplicateTransactionService {
  DuplicateTransactionService._();

  static final SupabaseClient _client = Supabase.instance.client;

  static Future<DuplicateTransactionCandidate?> findPossibleDuplicate({
    required String customerId,
    required String entryType,
    required double amount,
    required DateTime transactionDate,
    String? paymentMethod,
  }) async {
    final start = transactionDate.subtract(const Duration(minutes: 15));
    final end = transactionDate.add(const Duration(minutes: 15));
    final rows = await _client
        .from('ledger_entries')
        .select('id, entry_type, amount, amount_received, payment_method, transaction_date, notes')
        .eq('customer_id', customerId)
        .eq('entry_type', entryType)
        .gte('transaction_date', start.toUtc().toIso8601String())
        .lte('transaction_date', end.toUtc().toIso8601String())
        .order('transaction_date', ascending: false)
        .limit(10);

    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw);
      final existingAmount = ((entryType == 'payment'
                  ? row['amount_received']
                  : row['amount']) as num?)
              ?.toDouble() ??
          0;
      final sameAmount = (existingAmount - amount).abs() < 0.005;
      final existingMethod = row['payment_method']?.toString();
      final methodMatches = paymentMethod == null ||
          paymentMethod.isEmpty ||
          existingMethod == null ||
          existingMethod == paymentMethod;
      if (sameAmount && methodMatches) {
        return DuplicateTransactionCandidate(
          id: row['id'].toString(),
          entryType: row['entry_type']?.toString() ?? entryType,
          amount: existingAmount,
          transactionDate: DateTime.tryParse(row['transaction_date']?.toString() ?? ''),
          paymentMethod: existingMethod,
          notes: row['notes']?.toString(),
        );
      }
    }
    return null;
  }
}

class DuplicateTransactionCandidate {
  const DuplicateTransactionCandidate({
    required this.id,
    required this.entryType,
    required this.amount,
    required this.transactionDate,
    this.paymentMethod,
    this.notes,
  });

  final String id;
  final String entryType;
  final double amount;
  final DateTime? transactionDate;
  final String? paymentMethod;
  final String? notes;
}
