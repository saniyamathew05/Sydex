import 'package:supabase_flutter/supabase_flutter.dart';

class PurchaseService {
  static final SupabaseClient _supabase = Supabase.instance.client;

  /// Ensures the supplied customer is a real customer record before writing.
  static Future<void> _validateCustomer(String customerId) async {
    final normalizedId = customerId.trim();

    if (normalizedId.isEmpty ||
        normalizedId.toLowerCase() == 'customer' ||
        normalizedId.toLowerCase() == 'null') {
      throw Exception(
        'Please select a valid customer before saving the purchase.',
      );
    }

    final customer = await _supabase
        .from('customers')
        .select('id')
        .eq('id', normalizedId)
        .maybeSingle();

    if (customer == null) {
      throw Exception(
        'The selected customer was not found. Please select a customer from the customer list.',
      );
    }
  }

  /// Records a new customer purchase.
  ///
  /// Adds the sale amount less any discount to the customer's balance.
  static Future<Map<String, dynamic>?> recordPurchase({
    required String customerId,
    required double amount,
    double discount = 0,
    String? notes,
    DateTime? transactionDate,
  }) async {
    final user = _supabase.auth.currentUser;

    if (user == null) {
      throw Exception('You are not logged in.');
    }

    await _validateCustomer(customerId);

    if (amount <= 0) {
      throw Exception('Purchase amount must be greater than zero.');
    }
    if (discount < 0 || discount >= amount) {
      throw Exception('Discount must be less than the purchase amount.');
    }

    final response = await _supabase.rpc(
      'record_purchase_with_discount',
      params: {
        'p_customer_id': customerId.trim(),
        'p_amount': amount,
        'p_discount': discount,
        'p_notes': notes == null || notes.trim().isEmpty ? null : notes.trim(),
        'p_transaction_date': (transactionDate ?? DateTime.now())
            .toIso8601String(),
      },
    );

    if (response == null) {
      throw Exception('The sale was not saved: the server returned no sale record.');
    }

    return Map<String, dynamic>.from(response as Map);
  }
}
