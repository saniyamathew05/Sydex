import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/customer.dart';
import 'supabase_pagination.dart';

class CustomerService {
  static final SupabaseClient _supabase = Supabase.instance.client;

  static final List<Customer> customers = [];

  static final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

  static bool isLoading = false;
  static String? errorMessage;
  static String? _cacheUserId;

  // ---------------------------------------------------------------------------
  // LOAD CUSTOMERS
  // ---------------------------------------------------------------------------

  static Future<void> loadCustomers() async {
    isLoading = true;
    errorMessage = null;
    dataVersion.value++;

    try {
      final user = _supabase.auth.currentUser;

      if (user == null) {
        if (_cacheUserId != null) customers.clear();
        _cacheUserId = null;
        throw Exception('No logged-in user found while loading customers.');
      }

      if (_cacheUserId != user.id) {
        customers.clear();
        _cacheUserId = user.id;
      }

      debugPrint('CustomerService: Loading customers for user ${user.id}');

      final response = await SupabasePagination.loadAll(
        (from, to) => _supabase
            .from('customers')
            .select(
              'id, business_name, location, phone, opening_balance, is_active, created_at',
            )
            .eq('is_active', true)
            .order('business_name', ascending: true)
            .order('id', ascending: true)
            .range(from, to),
      );

      final refreshedCustomers = <Customer>[];
      for (final row in response) {
        refreshedCustomers.add(
          Customer(
            id: row['id'] as String,
            businessName: row['business_name'] as String,
            location: row['location'] as String,
            phone: row['phone'] as String,
            openingBalance: (row['opening_balance'] as num).toDouble(),
          ),
        );
      }

      customers
        ..clear()
        ..addAll(refreshedCustomers);

      debugPrint('CustomerService: Loaded ${customers.length} customers');
    } catch (error, stackTrace) {
      errorMessage = error.toString();

      debugPrint('CustomerService ERROR: $error');

      debugPrint('CustomerService STACK TRACE: $stackTrace');
    } finally {
      isLoading = false;
      dataVersion.value++;
    }
  }

  // ---------------------------------------------------------------------------
  // ADD CUSTOMER
  // ---------------------------------------------------------------------------

  static Future<Customer?> addCustomer({
    required String businessName,
    required String location,
    String phone = '',
    double openingBalance = 0,
  }) async {
    errorMessage = null;

    try {
      final user = _supabase.auth.currentUser;

      if (user == null) {
        throw Exception('You must be logged in to add a customer.');
      }

      final profile = await _supabase
          .from('profiles')
          .select('company_id')
          .eq('id', user.id)
          .maybeSingle();
      final companyId = profile?['company_id']?.toString();
      if (companyId == null || companyId.isEmpty) {
        throw Exception('Your account is not linked to a company.');
      }

      final cleanBusinessName = businessName.trim();

      final cleanLocation = location.trim();

      final cleanPhone = phone.trim();

      if (cleanBusinessName.isEmpty) {
        throw Exception('Business name is required.');
      }

      if (cleanLocation.isEmpty) {
        throw Exception('Location is required.');
      }

      if (openingBalance < 0) {
        throw Exception('Opening balance cannot be negative.');
      }

      final response = await _supabase
          .from('customers')
          .insert({
            'company_id': companyId,
            'business_name': cleanBusinessName,
            'location': cleanLocation,
            'phone': cleanPhone,
            'opening_balance': openingBalance,
            'is_active': true,
          })
          .select(
            'id, business_name, location, phone, opening_balance, is_active, created_at',
          )
          .single();

      final customer = Customer(
        id: response['id'] as String,
        businessName: response['business_name'] as String,
        location: response['location'] as String,
        phone: response['phone'] as String,
        openingBalance: (response['opening_balance'] as num).toDouble(),
      );

      customers.add(customer);

      customers.sort(
        (a, b) => a.businessName.toLowerCase().compareTo(
          b.businessName.toLowerCase(),
        ),
      );

      dataVersion.value++;

      return customer;
    } catch (error, stackTrace) {
      errorMessage = error.toString();

      debugPrint('CustomerService ADD ERROR: $error');

      debugPrint('CustomerService ADD STACK TRACE: $stackTrace');

      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // UPDATE CUSTOMER
  // ---------------------------------------------------------------------------

  static Future<Customer?> updateCustomerPhone({
    required String customerId,
    required String phone,
  }) async {
    errorMessage = null;
    try {
      final row = await _supabase
          .rpc(
            'update_customer_phone',
            params: {'p_customer_id': customerId, 'p_phone': phone.trim()},
          )
          .select('id, business_name, location, phone, opening_balance')
          .single();
      final customer = Customer(
        id: row['id'] as String,
        businessName: row['business_name'] as String,
        location: row['location'] as String,
        phone: row['phone'] as String,
        openingBalance: (row['opening_balance'] as num).toDouble(),
      );
      final index = customers.indexWhere((item) => item.id == customerId);
      if (index != -1) customers[index] = customer;
      dataVersion.value++;
      return customer;
    } catch (error) {
      debugPrint('Customer phone update failed: $error');
      errorMessage = 'Could not save the phone number. Please try again.';
      return null;
    }
  }

  static Future<bool> updateCustomer({
    required String customerId,
    required String businessName,
    required String location,
    required String phone,
    double? openingBalance,
  }) async {
    errorMessage = null;

    try {
      final cleanBusinessName = businessName.trim();

      final cleanLocation = location.trim();

      final cleanPhone = phone.trim();

      if (cleanBusinessName.isEmpty) {
        throw Exception('Business name is required.');
      }

      if (cleanLocation.isEmpty) {
        throw Exception('Location is required.');
      }

      if (openingBalance != null && openingBalance < 0) {
        throw Exception('Opening balance cannot be negative.');
      }

      final updates = <String, dynamic>{
        'business_name': cleanBusinessName,
        'location': cleanLocation,
        'phone': cleanPhone,
      };
      if (openingBalance != null) {
        updates['opening_balance'] = openingBalance;
      }

      final response = await _supabase
          .from('customers')
          .update(updates)
          .eq('id', customerId)
          .select(
            'id, business_name, location, phone, opening_balance, is_active, created_at',
          )
          .maybeSingle();

      if (response == null) {
        throw Exception('Customer was not found.');
      }

      final index = customers.indexWhere(
        (customer) => customer.id == customerId,
      );

      if (index != -1) {
        customers[index] = Customer(
          id: response['id'] as String,
          businessName: response['business_name'] as String,
          location: response['location'] as String,
          phone: response['phone'] as String,
          openingBalance: (response['opening_balance'] as num).toDouble(),
        );

        customers.sort(
          (a, b) => a.businessName.toLowerCase().compareTo(
            b.businessName.toLowerCase(),
          ),
        );
      }

      dataVersion.value++;

      return true;
    } catch (error, stackTrace) {
      errorMessage = error.toString();

      debugPrint('CustomerService UPDATE ERROR: $error');

      debugPrint('CustomerService UPDATE STACK TRACE: $stackTrace');

      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // DELETE / DEACTIVATE CUSTOMER
  // ---------------------------------------------------------------------------

  static Future<bool> deleteCustomer(String customerId) async {
    errorMessage = null;

    try {
      // Customers are deactivated instead of physically deleted.
      // This preserves their payment and ledger history.

      final response = await _supabase
          .from('customers')
          .update({'is_active': false})
          .eq('id', customerId)
          .select('id')
          .maybeSingle();

      if (response == null) {
        throw Exception('Customer was not found.');
      }

      customers.removeWhere((customer) => customer.id == customerId);

      dataVersion.value++;

      return true;
    } catch (error, stackTrace) {
      errorMessage = error.toString();

      debugPrint('CustomerService DELETE ERROR: $error');

      debugPrint('CustomerService DELETE STACK TRACE: $stackTrace');

      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // FIND CUSTOMER
  // ---------------------------------------------------------------------------

  static Customer? getCustomerById(String id) {
    try {
      return customers.firstWhere((customer) => customer.id == id);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // SEARCH CUSTOMERS
  // ---------------------------------------------------------------------------

  static List<Customer> searchCustomers(String query) {
    final cleanQuery = query.trim().toLowerCase();

    if (cleanQuery.isEmpty) {
      return List<Customer>.from(customers);
    }

    return customers.where((customer) {
      return customer.businessName.toLowerCase().contains(cleanQuery) ||
          customer.location.toLowerCase().contains(cleanQuery) ||
          customer.phone.toLowerCase().contains(cleanQuery);
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // REFRESH
  // ---------------------------------------------------------------------------

  static Future<void> refresh() async {
    await loadCustomers();
  }

  // ---------------------------------------------------------------------------
  // CLEAR LOCAL DATA
  // ---------------------------------------------------------------------------

  static void clearLocalCustomers() {
    customers.clear();
    dataVersion.value++;
  }
}
