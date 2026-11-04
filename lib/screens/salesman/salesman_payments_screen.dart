import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/currency_formatter.dart';
import '../../services/payment_method_breakdown.dart';
import '../../services/ledger_user_name_service.dart';
import '../../services/transaction_service.dart';
import '../../services/customer_service.dart';
import '../../services/salesman_visit_service.dart';
import '../../services/payment_receipt_share_service.dart';
import '../../models/customer.dart';

class SalesmanPaymentsScreen extends StatefulWidget {
  const SalesmanPaymentsScreen({super.key});

  @override
  State<SalesmanPaymentsScreen> createState() => _SalesmanPaymentsScreenState();
}

class _SalesmanPaymentsScreenState extends State<SalesmanPaymentsScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _payments = [];

  bool _isLoading = true;
  String? _loadError;
  String _searchQuery = '';
  String _dateFilter = 'today';
  String _methodFilter = 'all';
  String _salesmanFilter = 'all';
  bool _showFilters = false;
  DateTime? _selectedDate;
  DateTimeRange? _selectedDateRange;
  Set<String> _assignedCustomerIds = <String>{};

  List<Map<String, dynamic>> get _paymentsForSummary => _payments
      .where(_matchesDate)
      .where(_matchesMethod)
      .where(_matchesSalesman)
      .toList(growable: false);

  double get _selectedPaymentsTotal =>
      _paymentsForSummary.fold<double>(0, (total, payment) {
        if (payment['entry_type']?.toString().toLowerCase() == 'refusal') {
          return total;
        }
        final received =
            (payment['amount_received'] as num?)?.toDouble() ??
            ((payment['amount'] as num?)?.toDouble() ?? 0) -
                ((payment['discount'] as num?)?.toDouble() ?? 0);
        final method = _methodFilter;
        final note = payment['payment_method_note']?.toString();
        final isSplit = PaymentMethodBreakdown.parse(note).isNotEmpty;
        final methodAmount = method == 'all'
            ? received
            : PaymentMethodBreakdown.amountFor(
                note: note,
                method: method,
                fallbackAmount: isSplit ? 0 : received,
              );
        return total + methodAmount;
      });

  int get _selectedPaymentsCount => _paymentsForSummary.length;

  int get _paidAssignedCustomerCount {
    return _paymentsForSummary
        .map((payment) => payment['customer_id']?.toString())
        .whereType<String>()
        .where(_assignedCustomerIds.contains)
        .toSet()
        .length;
  }

  String get _selectedPeriodLabel => switch (_dateFilter) {
    'today' => 'Today',
    'week' => 'This week',
    'month' => 'This month',
    'date' when _selectedDate != null =>
      '${_selectedDate!.day.toString().padLeft(2, '0')}/'
          '${_selectedDate!.month.toString().padLeft(2, '0')}/'
          '${_selectedDate!.year}',
    _ => 'All dates',
  };

  @override
  void initState() {
    super.initState();

    _loadPayments();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPayments() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('You are not logged in.');

      try {
        // Prefer the owner-assigned customer IDs. Older route assignments do
        // not have these IDs yet, so retain the location-based assignment as
        // a compatibility fallback instead of displaying 0 / 0.
        final values = await Future.wait<dynamic>([
          CustomerService.loadCustomers(),
          SalesmanVisitService.loadTodayCustomerIds(),
          SalesmanVisitService.loadTodayRoute(),
        ]);
        final customerIds = Set<String>.from(values[1] as Set<String>);
        _assignedCustomerIds = customerIds;
      } catch (error) {
        debugPrint('Could not load assigned customer count: $error');
        _assignedCustomerIds = <String>{};
      }

      // Salesmen share the payment history, including entries made by their
      // teammates. Receiver names are resolved separately through the
      // restricted RPC because salesman accounts cannot read other profiles.
      const paymentColumns = '''
            id,
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
            user_id,
            customer_id,
            hidden_from_ledger,
            customers (business_name, location, phone)
          ''';
      List<dynamic> response;
      try {
        response = await _supabase
            .from('payments')
            .select(paymentColumns)
            .order('transaction_date', ascending: false);
      } catch (error) {
        // Older databases may not have the optional shared visibility column.
        debugPrint('Payment visibility column unavailable: $error');
        try {
          response = await _supabase
              .from('payments')
              .select(paymentColumns.replaceFirst('hidden_from_ledger,', ''))
              .order('transaction_date', ascending: false);
        } catch (fallbackError) {
          // A stale PostgREST schema cache can also reject the nested customer
          // relationship. Load the payment rows so the screen remains usable.
          debugPrint('Payment relationship unavailable: $fallbackError');
          response = await _supabase
              .from('payments')
              .select(
                paymentColumns
                    .replaceFirst('hidden_from_ledger,', '')
                    .replaceFirst(
                      'customers (business_name, location, phone)',
                      '',
                    ),
              )
              .order('transaction_date', ascending: false);
        }
      }
      final payments = List<Map<String, dynamic>>.from(response);

      // Include refused visits as red, zero-amount payment-history events.
      if (_assignedCustomerIds.isNotEmpty) {
        try {
          final refusals = await _supabase
              .from('salesman_customer_daily_status')
              .select('id, customer_id, status_date, note, entered_by')
              .eq('status', 'rejected')
              .inFilter('customer_id', _assignedCustomerIds.toList());
          final customerById = {
            for (final customer in CustomerService.customers)
              customer.id: customer,
          };
          payments.addAll(
            (refusals as List).map((row) {
              final customer = customerById[row['customer_id']?.toString()];
              return <String, dynamic>{
                'id': 'refusal-${row['id']}',
                'entry_type': 'refusal',
                'customer_id': row['customer_id'],
                'transaction_date': '${row['status_date']}T00:00:00',
                'created_at': row['status_date'],
                'amount': 0,
                'amount_received': 0,
                'payment_method': 'refused',
                'payment_method_note': row['note']?.toString() ?? '',
                'notes': row['note']?.toString() ?? 'Customer refused payment',
                'user_id': row['entered_by'],
                'customers': customer == null
                    ? null
                    : {
                        'business_name': customer.businessName,
                        'location': customer.location,
                      },
              };
            }),
          );
        } catch (error) {
          debugPrint('Could not load refused payment history: $error');
        }
      }

      // Resolve only the receiver names needed for these visible payment rows.
      // The RPC exposes names, not the rest of another user's profile.
      try {
        final receiverNames = await LedgerUserNameService.loadNames(
          payments.map((payment) => payment['user_id']?.toString()),
        );
        for (final payment in payments) {
          final name = receiverNames[payment['user_id']?.toString()];
          if (name != null) payment['profiles'] = {'name': name};
        }
      } catch (error) {
        debugPrint('Could not load payment receiver names: $error');
      }

      if (!mounted) return;

      setState(() {
        _payments = payments;
        _loadError = null;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _loadError = error.toString();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not load payments.'),

          action: SnackBarAction(label: 'Retry', onPressed: _loadPayments),
        ),
      );
    }
  }

  String _formatDate(String date) {
    final parsed = DateTime.tryParse(date);

    if (parsed == null) {
      return date;
    }

    final local = parsed.toLocal();
    // transaction_date was written with the phone's local time when the
    // payment was entered. Use it for both the date and time so older rows
    // also show their original phone time instead of the server's created_at.

    final day = local.day.toString().padLeft(2, '0');

    final month = local.month.toString().padLeft(2, '0');

    final year = local.year.toString();

    final hour = local.hour.toString().padLeft(2, '0');

    final minute = local.minute.toString().padLeft(2, '0');

    return '$day/$month/$year • $hour:$minute';
  }

  String _formatPaymentMethod(Object? rawMethod) {
    final method = rawMethod?.toString().trim().replaceAll('_', ' ') ?? '';
    if (method.isEmpty) return 'Not specified';
    return method
        .split(' ')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
  }

  Future<void> _openPaymentDetails(Map<String, dynamic> payment) async {
    await Navigator.push(
      context,

      MaterialPageRoute(
        builder: (_) => SalesmanPaymentDetailsScreen(payment: payment),
      ),
    );
  }

  Future<void> _shareReceipt(Map<String, dynamic> payment) async {
    final customer = payment['customers'];
    if (customer is! Map) return;
    final customerId = payment['customer_id']?.toString();
    if (customerId == null || customerId.isEmpty) return;
    final model = Customer(
      id: customerId,
      businessName: customer['business_name']?.toString() ?? 'Customer',
      location: customer['location']?.toString() ?? '',
      phone: customer['phone']?.toString() ?? '',
    );
    try {
      await PaymentReceiptShareService.shareLatest(
        context: context,
        customer: model,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  String _customerName(Map<String, dynamic> payment) {
    final customer = payment['customers'];

    if (customer is Map) {
      return customer['business_name']?.toString() ?? 'Customer';
    }

    return 'Customer';
  }

  String _receiverName(Map<String, dynamic> payment) {
    final profile = payment['profiles'];

    if (profile is Map) {
      final name = profile['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) return name;
    }

    return payment['user_id']?.toString() == _supabase.auth.currentUser?.id
        ? 'You'
        : 'Another team member';
  }

  bool _matchesDate(Map<String, dynamic> payment) {
    final dateString = payment['transaction_date']?.toString();
    final parsed = dateString == null
        ? null
        : DateTime.tryParse(dateString)?.toLocal();
    if (parsed == null) return false;

    final day = DateTime(parsed.year, parsed.month, parsed.day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_dateFilter) {
      case 'today':
        return day == today;
      case 'week':
        final weekStart = today.subtract(Duration(days: today.weekday - 1));
        return !day.isBefore(weekStart) && !day.isAfter(today);
      case 'month':
        return day.year == today.year && day.month == today.month;
      case 'date':
        final range = _selectedDateRange;
        if (range != null) {
          final start = DateTime(
            range.start.year,
            range.start.month,
            range.start.day,
          );
          final end = DateTime(range.end.year, range.end.month, range.end.day);
          return !day.isBefore(start) && !day.isAfter(end);
        }
        final selected = _selectedDate;
        return selected == null ||
            day == DateTime(selected.year, selected.month, selected.day);
      default:
        return true;
    }
  }

  bool _matchesMethod(Map<String, dynamic> payment) {
    if (_methodFilter == 'all') return true;
    if (_methodFilter == 'refused') {
      return payment['entry_type']?.toString().toLowerCase() == 'refusal';
    }
    if (payment['entry_type']?.toString().toLowerCase() == 'refusal')
      return false;
    final method = payment['payment_method']
        ?.toString()
        .trim()
        .toLowerCase()
        .replaceAll(' ', '_');
    return method == _methodFilter ||
        PaymentMethodBreakdown.includes(
          payment['payment_method_note']?.toString(),
          _methodFilter,
        );
  }

  bool _matchesSalesman(Map<String, dynamic> payment) {
    if (_salesmanFilter == 'all') return true;
    return payment['user_id']?.toString() == _salesmanFilter;
  }

  List<Map<String, dynamic>> get _filteredPayments {
    final query = _searchQuery.trim().toLowerCase();
    return _payments.where((payment) {
      if (!_matchesDate(payment)) return false;
      if (!_matchesMethod(payment)) return false;
      if (!_matchesSalesman(payment)) return false;
      if (query.isEmpty) return true;
      final customer = payment['customers'];
      final values = <String>[
        _customerName(payment),
        if (customer is Map) customer['location']?.toString() ?? '',
        _receiverName(payment),
        payment['payment_method']?.toString() ?? '',
        payment['payment_method_note']?.toString() ?? '',
        payment['notes']?.toString() ?? '',
      ];
      return values.any((value) => value.toLowerCase().contains(query));
    }).toList();
  }

  Future<void> _chooseDate() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange:
          _selectedDateRange ??
          DateTimeRange(start: _selectedDate ?? now, end: _selectedDate ?? now),
      helpText: 'Filter team payments by date range',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedDate = picked.start;
      _selectedDateRange = picked;
      _dateFilter = 'date';
    });
  }

  void _resetFilters() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _dateFilter = 'today';
      _methodFilter = 'all';
      _salesmanFilter = 'all';
      _selectedDate = null;
      _selectedDateRange = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Payments Received',

          style: TextStyle(fontWeight: FontWeight.w700),
        ),

        actions: [
          IconButton(
            tooltip: 'Refresh',

            onPressed: _isLoading ? null : _loadPayments,

            icon: const Icon(Icons.refresh_rounded),
          ),

          const SizedBox(width: 4),
        ],
      ),

      body: RefreshIndicator(
        onRefresh: _loadPayments,

        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_payments.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),

        padding: const EdgeInsets.all(20),

        children: [
          const SizedBox(height: 90),

          if (_loadError != null) ...[
            Text(
              'Could not load payments. Pull down to retry.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
          ],

          _EmptyPaymentsState(
            onRefresh: _loadPayments,
            message: 'No team payments are available yet.',
          ),
        ],
      );
    }

    final payments = _filteredPayments;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),

      padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),

      children: [
        _buildSummaryHeader(),

        const SizedBox(height: 20),

        _buildFilters(),

        const SizedBox(height: 24),

        Row(
          children: [
            const Expanded(
              child: Text(
                'Team Payment History',

                style: TextStyle(
                  fontSize: 21,

                  fontWeight: FontWeight.w800,

                  letterSpacing: -0.3,
                ),
              ),
            ),

            Tooltip(
              message:
                  'Assigned customers with a payment matching the selected filters',
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),

                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,

                  borderRadius: BorderRadius.circular(20),
                ),

                child: Text(
                  '$_paidAssignedCustomerCount / ${_assignedCustomerIds.length} paid',

                  style: const TextStyle(
                    fontWeight: FontWeight.w700,

                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        if (payments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 36),
            child: Text(
              'No payments match these filters.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ...payments.map((payment) => _buildPaymentCard(payment)),
      ],
    );
  }

  Widget _buildFilters() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _searchQuery = value),
                decoration: InputDecoration(
                  labelText: 'Search team payments',
                  hintText: 'Customer, location, method, or note',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                          icon: const Icon(Icons.clear_rounded),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => setState(() => _showFilters = !_showFilters),
              icon: Icon(
                _showFilters
                    ? Icons.filter_alt_off_rounded
                    : Icons.filter_alt_rounded,
              ),
              label: Text(_showFilters ? 'Hide' : 'Filters'),
            ),
          ],
        ),
        if (_showFilters) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _dateFilter,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Date'),
            items: const [
              DropdownMenuItem(value: 'today', child: Text('Today')),
              DropdownMenuItem(value: 'all', child: Text('All dates')),
              DropdownMenuItem(value: 'week', child: Text('This week')),
              DropdownMenuItem(value: 'month', child: Text('This month')),
              DropdownMenuItem(
                value: 'date',
                child: Text('Choose date range…'),
              ),
            ],
            onChanged: (value) {
              if (value == null) return;
              if (value == 'date') {
                _chooseDate();
              } else {
                setState(() {
                  _dateFilter = value;
                  _selectedDate = null;
                  _selectedDateRange = null;
                });
              }
            },
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _methodFilter,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Method'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All methods')),
              DropdownMenuItem(value: 'cash', child: Text('Cash')),
              DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
              DropdownMenuItem(value: 'neft', child: Text('NEFT')),
              DropdownMenuItem(value: 'gpay', child: Text('GPay / Online')),
              DropdownMenuItem(value: 'refused', child: Text('Refused')),
            ],
            onChanged: (value) =>
                setState(() => _methodFilter = value ?? 'all'),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _salesmanFilter,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Salesman'),
            items: [
              const DropdownMenuItem(value: 'all', child: Text('All salesmen')),
              ..._salesmanOptions.entries.map(
                (entry) => DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
            onChanged: (value) =>
                setState(() => _salesmanFilter = value ?? 'all'),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _resetFilters,
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Reset filters'),
            ),
          ),
          if (_dateFilter == 'date' && _selectedDateRange != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Dates: ${_selectedDateRange!.start.day}/${_selectedDateRange!.start.month}/${_selectedDateRange!.start.year} – '
                '${_selectedDateRange!.end.day}/${_selectedDateRange!.end.month}/${_selectedDateRange!.end.year}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Map<String, String> get _salesmanOptions {
    final result = <String, String>{};
    for (final payment in _payments) {
      final id = payment['user_id']?.toString();
      if (id == null || id.isEmpty) continue;
      result[id] = _receiverName(payment);
    }
    return result;
  }

  Widget _buildSummaryHeader() {
    final methodLabel = _methodFilter == 'all'
        ? 'All payment methods'
        : _formatPaymentMethod(_methodFilter);
    final summaryTitle = _methodFilter == 'all'
        ? 'Team Total • $_selectedPeriodLabel'
        : '$methodLabel Total • $_selectedPeriodLabel';

    return Container(
      width: double.infinity,

      padding: const EdgeInsets.all(22),

      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,

          end: Alignment.bottomRight,

          colors: [
            Theme.of(context).colorScheme.primary,

            Theme.of(context).colorScheme.primary.withValues(alpha: 0.82),
          ],
        ),

        borderRadius: BorderRadius.circular(24),

        boxShadow: [
          BoxShadow(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.20),

            blurRadius: 22,

            offset: const Offset(0, 10),
          ),
        ],
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(11),

                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),

                  borderRadius: BorderRadius.circular(14),
                ),

                child: const Icon(
                  Icons.account_balance_wallet_outlined,

                  color: Colors.white,

                  size: 23,
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Text(
                  summaryTitle,
                  style: const TextStyle(
                    color: Colors.white,

                    fontSize: 15,

                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                CurrencyFormatter.rupees(_selectedPaymentsTotal),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                ),
              ),
            ),
          ),

          const SizedBox(height: 5),

          Text(
            'Combined total received by both salesmen',

            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.76),

              fontSize: 13,
            ),
          ),

          const SizedBox(height: 20),

          Row(
            children: [
              Expanded(
                child: _SummaryMetric(
                  title: 'Payments in selection',

                  value: '$_selectedPaymentsCount',
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: _SummaryMetric(
                  title: 'Method filter',

                  value: methodLabel,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentCard(Map<String, dynamic> payment) {
    if (payment['entry_type']?.toString().toLowerCase() == 'refusal') {
      final customerName = _customerName(payment);
      final date = payment['transaction_date'] as String? ?? '';
      final note = payment['notes']?.toString() ?? 'Customer refused payment';
      final error = Theme.of(context).colorScheme.error;
      return Container(
        margin: const EdgeInsets.only(bottom: 11),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: error),
        ),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: error,
            child: Icon(
              Icons.block_outlined,
              color: Theme.of(context).colorScheme.onError,
            ),
          ),
          title: Text(
            customerName,
            style: TextStyle(fontWeight: FontWeight.w800, color: error),
          ),
          subtitle: Text('Payment refused • ${_formatDate(date)}\n$note'),
          trailing: Text(
            'Refused',
            style: TextStyle(fontWeight: FontWeight.w800, color: error),
          ),
        ),
      );
    }
    final customer = payment['customers'];

    final customerName = _customerName(payment);

    final location = customer is Map
        ? customer['location']?.toString() ?? ''
        : '';

    final receiverName = _receiverName(payment);
    final splitMethodDisplay = PaymentMethodBreakdown.display(
      payment['payment_method_note']?.toString(),
    );
    final paymentMethod =
        splitMethodDisplay ?? _formatPaymentMethod(payment['payment_method']);
    final methodNote =
        PaymentMethodBreakdown.additionalNote(
          payment['payment_method_note']?.toString().trim(),
        ) ??
        '';

    final settlementAmount = (payment['amount'] as num?)?.toDouble() ?? 0;

    final discount = (payment['discount'] as num?)?.toDouble() ?? 0;

    final amountReceived =
        (payment['amount_received'] as num?)?.toDouble() ??
        (settlementAmount - discount);
    final amountForSelectedMethod = _methodFilter == 'all'
        ? amountReceived
        : PaymentMethodBreakdown.amountFor(
            note: payment['payment_method_note']?.toString(),
            method: _methodFilter,
            fallbackAmount:
                PaymentMethodBreakdown.parse(
                  payment['payment_method_note']?.toString(),
                ).isEmpty
                ? amountReceived
                : 0,
          );

    final date = payment['transaction_date'] as String? ?? '';

    final hasSignature =
        payment['signature_path'] != null &&
        payment['signature_path'].toString().isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 11),

      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,

        borderRadius: BorderRadius.circular(20),

        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.50),
        ),
      ),

      child: InkWell(
        borderRadius: BorderRadius.circular(20),

        onTap: () => _openPaymentDetails(payment),

        child: Padding(
          padding: const EdgeInsets.all(12),

          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,

            children: [
              Container(
                width: 50,

                height: 50,

                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,

                  borderRadius: BorderRadius.circular(15),
                ),

                child: Icon(
                  Icons.payments_outlined,

                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),

              const SizedBox(width: 9),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Text(
                      customerName,

                      maxLines: 1,

                      overflow: TextOverflow.ellipsis,

                      style: const TextStyle(
                        fontWeight: FontWeight.w800,

                        fontSize: 15,
                      ),
                    ),

                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 4),

                      Row(
                        children: [
                          Icon(
                            Icons.location_on_outlined,

                            size: 13,

                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),

                          const SizedBox(width: 3),

                          Expanded(
                            child: Text(
                              location,

                              maxLines: 1,

                              overflow: TextOverflow.ellipsis,

                              style: TextStyle(
                                fontSize: 11,

                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],

                    const SizedBox(height: 5),

                    Text(
                      'Received by $receiverName',

                      maxLines: 1,

                      overflow: TextOverflow.ellipsis,

                      style: TextStyle(
                        fontSize: 11,

                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),

                    const SizedBox(height: 3),

                    Text(
                      _formatDate(date),

                      style: TextStyle(
                        fontSize: 11,

                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Method: $paymentMethod${methodNote.isEmpty ? '' : ' • $methodNote'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (discount > 0) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Discount given: ${CurrencyFormatter.rupees(discount)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(width: 6),

              SizedBox(
                width: 86,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        '+${CurrencyFormatter.rupees(amountForSelectedMethod)}',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Colors.green.shade700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Share receipt',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () => _shareReceipt(payment),
                          icon: Icon(
                            Icons.share_outlined,
                            size: 17,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 5),
                        if (hasSignature)
                          Icon(
                            Icons.draw_outlined,
                            size: 15,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 19,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================

// SUMMARY METRIC

// ============================================================

class _SummaryMetric extends StatelessWidget {
  final String title;

  final String value;

  const _SummaryMetric({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),

      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),

        borderRadius: BorderRadius.circular(14),
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Text(
            title,

            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),

              fontSize: 11,
            ),
          ),

          const SizedBox(height: 4),

          Text(
            value,

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: const TextStyle(
              color: Colors.white,

              fontSize: 16,

              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================

// EMPTY STATE

// ============================================================

class _EmptyPaymentsState extends StatelessWidget {
  final VoidCallback onRefresh;
  final String message;

  const _EmptyPaymentsState({
    required this.onRefresh,
    this.message = 'No payments received yet',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),

      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),

        borderRadius: BorderRadius.circular(22),
      ),

      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),

            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,

              shape: BoxShape.circle,
            ),

            child: Icon(
              Icons.receipt_long_outlined,

              size: 34,

              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),

          const SizedBox(height: 16),

          Text(
            message,

            textAlign: TextAlign.center,

            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),

          const SizedBox(height: 7),

          Text(
            'Payments received from customers will appear here.',

            textAlign: TextAlign.center,

            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,

              height: 1.4,
            ),
          ),

          const SizedBox(height: 18),

          OutlinedButton.icon(
            onPressed: onRefresh,

            icon: const Icon(Icons.refresh_rounded),

            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

// ============================================================

// PAYMENT DETAILS

// ============================================================

class SalesmanPaymentDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> payment;

  const SalesmanPaymentDetailsScreen({super.key, required this.payment});

  @override
  State<SalesmanPaymentDetailsScreen> createState() =>
      _SalesmanPaymentDetailsScreenState();
}

class _SalesmanPaymentDetailsScreenState
    extends State<SalesmanPaymentDetailsScreen> {
  Uint8List? _signature;

  bool _isLoadingSignature = false;

  bool _signatureAttempted = false;

  Future<void> _loadSignature() async {
    final signaturePath = widget.payment['signature_path'] as String?;

    if (signaturePath == null || signaturePath.isEmpty) {
      if (mounted) {
        setState(() {
          _signatureAttempted = true;
        });
      }

      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingSignature = true;
      });
    }

    try {
      final bytes = await TransactionService.downloadSignature(signaturePath);

      if (!mounted) return;

      setState(() {
        _signature = bytes;

        _isLoadingSignature = false;

        _signatureAttempted = true;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _signature = null;

        _isLoadingSignature = false;

        _signatureAttempted = true;
      });
    }
  }

  String _formatDate(String date) {
    final parsed = DateTime.tryParse(date);

    if (parsed == null) {
      return date;
    }

    final local = parsed.toLocal();
    final day = local.day.toString().padLeft(2, '0');

    final month = local.month.toString().padLeft(2, '0');

    final year = local.year.toString();

    final hour = local.hour.toString().padLeft(2, '0');

    final minute = local.minute.toString().padLeft(2, '0');

    return '$day/$month/$year • $hour:$minute';
  }

  String _formatPaymentMethod(Object? rawMethod) {
    final method = rawMethod?.toString().trim().replaceAll('_', ' ') ?? '';
    if (method.isEmpty) return 'Not specified';
    return method
        .split(' ')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
  }

  @override
  void initState() {
    super.initState();

    _loadSignature();
  }

  @override
  Widget build(BuildContext context) {
    final payment = widget.payment;

    final customer = payment['customers'];

    final profile = payment['profiles'];

    final customerName = customer is Map
        ? customer['business_name']?.toString() ?? 'Customer'
        : 'Customer';

    final location = customer is Map
        ? customer['location']?.toString() ?? ''
        : '';

    final phone = customer is Map ? customer['phone']?.toString() ?? '' : '';

    final receiverName = profile is Map
        ? profile['name']?.toString() ?? 'User'
        : 'User';

    final settlementAmount = (payment['amount'] as num?)?.toDouble() ?? 0;

    final discount = (payment['discount'] as num?)?.toDouble() ?? 0;

    final amountReceived =
        (payment['amount_received'] as num?)?.toDouble() ??
        (settlementAmount - discount);

    final previousBalance =
        (payment['previous_balance'] as num?)?.toDouble() ?? 0;

    final remainingBalance =
        (payment['remaining_balance'] as num?)?.toDouble() ?? 0;

    final date = payment['transaction_date'] as String? ?? '';

    final notes = payment['notes'] as String? ?? '';

    final paymentMethodNote =
        payment['payment_method_note']?.toString().trim() ?? '';
    final paymentMethod =
        PaymentMethodBreakdown.display(paymentMethodNote) ??
        _formatPaymentMethod(payment['payment_method']);

    final hasSignaturePath =
        payment['signature_path'] != null &&
        payment['signature_path'].toString().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Payment Details',

          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),

      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),

        children: [
          // Success header

          Container(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),

            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),

              borderRadius: BorderRadius.circular(22),
            ),

            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(13),

                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),

                    shape: BoxShape.circle,
                  ),

                  child: const Icon(
                    Icons.check_circle_rounded,

                    size: 46,

                    color: Colors.green,
                  ),
                ),

                const SizedBox(height: 13),

                const Text(
                  'Payment Received',

                  textAlign: TextAlign.center,

                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
                ),

                const SizedBox(height: 6),

                Text(
                  _formatDate(date),

                  textAlign: TextAlign.center,

                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,

                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Amount
          Container(
            padding: const EdgeInsets.all(24),

            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,

                end: Alignment.bottomRight,

                colors: [
                  Theme.of(context).colorScheme.primaryContainer,

                  Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.65),
                ],
              ),

              borderRadius: BorderRadius.circular(22),
            ),

            child: Column(
              children: [
                Text(
                  'Amount Received',

                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,

                    fontWeight: FontWeight.w600,
                  ),
                ),

                const SizedBox(height: 6),

                Text(
                  '${CurrencyFormatter.rupees(amountReceived)}',

                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,

                    fontSize: 34,

                    fontWeight: FontWeight.w800,

                    letterSpacing: -0.8,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          _InfoCard(
            icon: Icons.storefront_outlined,

            title: 'Customer',

            children: [
              _InfoRow(label: 'Business', value: customerName),

              if (location.isNotEmpty)
                _InfoRow(label: 'Location', value: location),

              if (phone.isNotEmpty) _InfoRow(label: 'Phone', value: phone),
            ],
          ),

          const SizedBox(height: 12),

          _InfoCard(
            icon: Icons.account_balance_wallet_outlined,

            title: 'Payment Information',

            children: [
              _InfoRow(label: 'Received by', value: receiverName),

              _InfoRow(label: 'Payment method', value: paymentMethod),

              if (paymentMethodNote.isNotEmpty)
                _InfoRow(label: 'Method note', value: paymentMethodNote),

              _InfoRow(
                label: 'Balance before',

                value: '${CurrencyFormatter.rupees(previousBalance)}',
              ),

              _InfoRow(
                label: 'Settlement',

                value: '${CurrencyFormatter.rupees(settlementAmount)}',
              ),

              if (discount > 0)
                _InfoRow(
                  label: 'Discount',

                  value: '${CurrencyFormatter.rupees(discount)}',
                ),

              _InfoRow(
                label: 'Amount received',

                value: '${CurrencyFormatter.rupees(amountReceived)}',
              ),

              _InfoRow(
                label: 'Balance after',

                value: '${CurrencyFormatter.rupees(remainingBalance)}',

                valueColor: remainingBalance == 0
                    ? Colors.green.shade700
                    : null,
              ),
            ],
          ),

          if (notes.trim().isNotEmpty) ...[
            const SizedBox(height: 12),

            _InfoCard(
              icon: Icons.notes_rounded,

              title: 'Payment Note',

              children: [Text(notes, style: const TextStyle(height: 1.45))],
            ),
          ],

          if (hasSignaturePath) ...[
            const SizedBox(height: 12),

            _InfoCard(
              icon: Icons.draw_outlined,

              title: 'Customer Signature',

              children: [
                const SizedBox(height: 2),

                if (_isLoadingSignature)
                  const Padding(
                    padding: EdgeInsets.all(28),

                    child: Center(child: CircularProgressIndicator()),
                  ),

                if (!_isLoadingSignature && _signature != null)
                  Container(
                    width: double.infinity,

                    height: 220,

                    padding: const EdgeInsets.all(12),

                    decoration: BoxDecoration(
                      color: Colors.white,

                      borderRadius: BorderRadius.circular(14),

                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),

                    child: Image.memory(_signature!, fit: BoxFit.contain),
                  ),

                if (!_isLoadingSignature &&
                    _signature == null &&
                    _signatureAttempted)
                  Container(
                    width: double.infinity,

                    padding: const EdgeInsets.all(20),

                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,

                      borderRadius: BorderRadius.circular(14),
                    ),

                    child: Column(
                      children: [
                        Icon(
                          Icons.image_not_supported_outlined,

                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),

                        const SizedBox(height: 8),

                        const Text('Signature could not be loaded.'),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================

// INFO CARD

// ============================================================

class _InfoCard extends StatelessWidget {
  final IconData icon;

  final String title;

  final List<Widget> children;

  const _InfoCard({
    required this.icon,

    required this.title,

    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),

      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,

        borderRadius: BorderRadius.circular(20),

        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),

                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,

                  borderRadius: BorderRadius.circular(10),
                ),

                child: Icon(
                  icon,

                  size: 19,

                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),

              const SizedBox(width: 10),

              Text(
                title,

                style: const TextStyle(
                  fontSize: 16,

                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          ...children,
        ],
      ),
    );
  }
}

// ============================================================

// INFO ROW

// ============================================================

class _InfoRow extends StatelessWidget {
  final String label;

  final String value;

  final Color? valueColor;

  const _InfoRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 11),

      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          SizedBox(
            width: 112,

            child: Text(
              label,

              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,

                fontSize: 13,
              ),
            ),
          ),

          Expanded(
            child: Text(
              value,

              style: TextStyle(fontWeight: FontWeight.w600, color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}
