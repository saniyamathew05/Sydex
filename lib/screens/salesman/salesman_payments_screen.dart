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
import '../../services/supabase_pagination.dart';
import '../../models/customer.dart';
import '../../theme/sydex_theme.dart';
import '../../services/owner_display_settings.dart';
import '../../widgets/root_back_guard.dart';
import '../../widgets/sydex_ui.dart';

class SalesmanPaymentsScreen extends StatefulWidget {
  const SalesmanPaymentsScreen({super.key});

  @override
  State<SalesmanPaymentsScreen> createState() => _SalesmanPaymentsScreenState();
}

class _SalesmanPaymentsScreenState extends State<SalesmanPaymentsScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _allPayments = [];

  bool get _showTeam => SalesmanDisplaySettings.show(SalesmanDisplaySettings.teamPayments);

  /// The loaded entries, without the kinds the owner chose not to show.
  List<Map<String, dynamic>> get _payments {
    final showRefused = SalesmanDisplaySettings.show(SalesmanDisplaySettings.refused);
    final me = _supabase.auth.currentUser?.id;
    return _allPayments.where((payment) {
      if (!showRefused &&
          payment['entry_type']?.toString().toLowerCase() == 'refusal') {
        return false;
      }
      return _showTeam || payment['user_id']?.toString() == me;
    }).toList();
  }

  bool _isLoading = true;
  String? _loadError;
  String _searchQuery = '';
  String _dateFilter = 'today';
  String _methodFilter = 'all';
  String _salesmanFilter = 'all';
  DateTime? _selectedDate;
  DateTimeRange? _selectedDateRange;
  Set<String> _assignedCustomerIds = <String>{};

  List<Map<String, dynamic>> get _paymentsForSummary => _payments
      .where(_matchesDate)
      .where(_matchesMethod)
      .where(_matchesSalesman)
      .where(
        (payment) =>
            payment['entry_type']?.toString().toLowerCase() != 'refusal' &&
            payment['is_bounced'] != true,
      )
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

  int get _refusedAssignedCustomerCount {
    return _payments
        .where(_matchesDate)
        .where(_matchesMethod)
        .where(_matchesSalesman)
        .where(
          (payment) =>
              payment['entry_type']?.toString().toLowerCase() == 'refusal',
        )
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

  String get _dateRangeFilterLabel {
    final range = _selectedDateRange;
    if (range == null) return 'Choose date range…';
    String format(DateTime date) =>
        '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}';
    return '${format(range.start)} – ${format(range.end)}';
  }

  @override
  void initState() {
    super.initState();

    SalesmanDisplaySettings.values.addListener(_onDisplayChanged);
    _loadPayments();
  }

  void _onDisplayChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SalesmanDisplaySettings.values.removeListener(_onDisplayChanged);
    _searchController.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _loadPaymentRows(String columns) =>
      SupabasePagination.loadAll(
        (from, to) => _supabase
            .from('payments')
            .select(columns)
            .order('transaction_date', ascending: false)
            .order('id', ascending: false)
            .range(from, to),
      );

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
            is_bounced,
            user_id,
            customer_id,
            hidden_from_ledger,
            customers (business_name, location, phone)
          ''';
      List<Map<String, dynamic>> response;
      try {
        response = await _loadPaymentRows(paymentColumns);
      } catch (error) {
        // Older databases may not have these optional payment columns.
        debugPrint('Optional payment columns unavailable: $error');
        try {
          response = await _loadPaymentRows(
            paymentColumns
                .replaceFirst('hidden_from_ledger,', '')
                .replaceFirst('is_bounced,', ''),
          );
        } catch (fallbackError) {
          // A stale PostgREST schema cache can also reject the nested customer
          // relationship. Load the payment rows so the screen remains usable.
          debugPrint('Payment relationship unavailable: $fallbackError');
          response = await _loadPaymentRows(
            paymentColumns
                .replaceFirst('hidden_from_ledger,', '')
                .replaceFirst('is_bounced,', '')
                .replaceFirst('customers (business_name, location, phone)', ''),
          );
        }
      }
      final payments = response;

      // Include every team refusal as a red, zero-amount history event. This
      // intentionally is not limited to today's assigned route: the selected
      // date filter is a team history filter and must show every refusal made
      // on that date.
      try {
        final refusals = await _supabase
            .from('salesman_customer_daily_status')
            .select(
              'id, customer_id, status_date, created_at, note, entered_by',
            )
            .eq('status', 'rejected');
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
              // Status date is the business date chosen by the executive.
              // Use it instead of created_at so date filtering remains exact
              // for late syncs and entries saved around midnight.
              'transaction_date': '${row['status_date']}T12:00:00',
              'created_at': row['created_at'] ?? row['status_date'],
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

      // Payment History is route-scoped. Once the salesman finishes a route,
      // loadTodayCustomerIds() returns no active customers and this list is
      // intentionally empty. Customer-specific history remains available from
      // the customer details screen, which uses its own customer ID lookup.
      final activeRouteCustomerIds = _assignedCustomerIds;
      final routePayments = payments.where((payment) {
        final customerId = payment['customer_id']?.toString();
        return customerId != null && activeRouteCustomerIds.contains(customerId);
      }).toList(growable: false);

      if (!mounted) return;

      setState(() {
        _allPayments = routePayments;
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
    if (payment['entry_type']?.toString().toLowerCase() == 'refusal') {
      return false;
    }
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
    final filtered = _payments.where((payment) {
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
    filtered.sort((a, b) {
      final aTransactionDate =
          DateTime.tryParse(a['transaction_date']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bTransactionDate =
          DateTime.tryParse(b['transaction_date']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final dateOrder = bTransactionDate.compareTo(aTransactionDate);
      if (dateOrder != 0) return dateOrder;
      final aCreated =
          DateTime.tryParse(a['created_at']?.toString() ?? '') ??
          aTransactionDate;
      final bCreated =
          DateTime.tryParse(b['created_at']?.toString() ?? '') ??
          bTransactionDate;
      return bCreated.compareTo(aCreated);
    });
    return filtered;
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
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _loadPayments,
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _buildContent(),
        ),
      ),
    );
  }

  Widget _header() => SydexScreenHeader(
    eyebrow: 'All payments received',
    title: 'Payments',
    leading: sydexCanGoBack(context)
        ? SydexIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          )
        : null,
    actions: [
      SydexIconButton(
        icon: Icons.refresh_rounded,
        tooltip: 'Refresh',
        onPressed: _isLoading ? null : _loadPayments,
      ),
    ],
  );

  Widget _buildContent() {
    if (_payments.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),

        padding: const EdgeInsets.all(20),

        children: [
          _header(),
          const SizedBox(height: 70),

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
    return SydexPageList(
      maxWidth: 960,
      top: 14,
      bottom: 30,
      children: [
        _header(),

        const SizedBox(height: 16),

        _buildSummaryHeader(),

        const SizedBox(height: 20),

        _buildFilters(),

        const SizedBox(height: 24),

        Row(
          children: [
            Expanded(
              child: Text(
                _showTeam ? 'Team payment history' : 'My payment history',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
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
                  'Paid $_paidAssignedCustomerCount  •  Refused $_refusedAssignedCustomerCount',

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
    final dateOptions = <String, String>{
      'Today': 'today',
      'This week': 'week',
      'This month': 'month',
      'All dates': 'all',
      _dateRangeFilterLabel: 'date',
    };
    const methodOptions = <String, String>{
      'All methods': 'all',
      'Cash': 'cash',
      'Cheque': 'cheque',
      'NEFT': 'neft',
      'GPay / Online': 'gpay',
      'Refused': 'refused',
    };
    final salesmanOptions = <String, String>{'All salesmen': 'all'};
    for (final entry in _salesmanOptions.entries) {
      var label = entry.value;
      while (salesmanOptions.containsKey(label)) {
        label = '$label ';
      }
      salesmanOptions[label] = entry.key;
    }
    String labelFor(Map<String, String> options, String value) => options
        .entries
        .firstWhere(
          (entry) => entry.value == value,
          orElse: () => options.entries.first,
        )
        .key;
    final filtered =
        _dateFilter != 'today' ||
        _methodFilter != 'all' ||
        _salesmanFilter != 'all' ||
        _searchQuery.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchController,
          onChanged: (value) => setState(() => _searchQuery = value),
          decoration: InputDecoration(
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
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final dropdowns = [
              SydexFilterDropdown(
                label: 'Date',
                options: dateOptions.keys.toList(),
                selected: labelFor(dateOptions, _dateFilter),
                onSelected: (label) {
                  final value = dateOptions[label]!;
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
              SydexFilterDropdown(
                label: 'Payment method',
                options: methodOptions.keys.toList(),
                selected: labelFor(methodOptions, _methodFilter),
                onSelected: (label) =>
                    setState(() => _methodFilter = methodOptions[label]!),
              ),
              if (salesmanOptions.length > 2)
                SydexFilterDropdown(
                  label: 'Salesman',
                  options: salesmanOptions.keys.toList(),
                  selected: labelFor(salesmanOptions, _salesmanFilter),
                  onSelected: (label) =>
                      setState(() => _salesmanFilter = salesmanOptions[label]!),
                ),
            ];
            final perRow = constraints.maxWidth >= 620
                ? dropdowns.length
                : 2;
            final width =
                (constraints.maxWidth - 10 * (perRow - 1)) / perRow;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (index, dropdown) in dropdowns.indexed)
                  SizedBox(
                    // A dropdown alone on the last line fills it.
                    width: perRow == 2 && index == 2
                        ? constraints.maxWidth
                        : width - .01,
                    child: dropdown,
                  ),
              ],
            );
          },
        ),
        if (filtered)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _resetFilters,
              child: const Text('Reset filters'),
            ),
          ),
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
        ? '${_showTeam ? 'Team' : 'My'} total • $_selectedPeriodLabel'
        : '$methodLabel Total • $_selectedPeriodLabel';

    return Container(
      width: double.infinity,

      padding: const EdgeInsets.all(22),

      decoration: BoxDecoration(
        color: SydexColors.hero(context),

        borderRadius: BorderRadius.circular(24),

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
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.7,
                ),
              ),
            ),
          ),

          const SizedBox(height: 5),

          Text(
            _showTeam
                ? 'Combined total received by all salesmen'
                : 'Total you received',

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
          color: SydexColors.refusedTint(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: SydexColors.refused(context)),
        ),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: SydexColors.refused(context),
            child: Icon(
              Icons.block_outlined,
              color: Theme.of(context).colorScheme.onError,
            ),
          ),
          title: Text(
            customerName,
            style: TextStyle(fontWeight: FontWeight.w600, color: error),
          ),
          subtitle: Text(
            'Payment refused • ${_formatDate(date)}\n$note\n'
            '${CurrencyFormatter.currentAmountDue(TransactionService.getCustomerBalance(payment['customer_id']?.toString() ?? ''))}',
          ),
          trailing: Text(
            'Refused',
            style: TextStyle(fontWeight: FontWeight.w600, color: error),
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

    final amountReceived = payment['is_bounced'] == true
        ? 0.0
        : (payment['amount_received'] as num?)?.toDouble() ??
              (settlementAmount - discount);
    final amountForSelectedMethod = payment['is_bounced'] == true
        ? 0.0
        : _methodFilter == 'all'
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
                        fontWeight: FontWeight.w600,

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
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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

              fontWeight: FontWeight.w600,
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

            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
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

    final amountReceived = payment['is_bounced'] == true
        ? 0.0
        : (payment['amount_received'] as num?)?.toDouble() ??
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.12),

                    shape: BoxShape.circle,
                  ),

                  child: Icon(
                    Icons.check_circle_rounded,

                    size: 46,

                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 13),

                const Text(
                  'Payment Received',

                  textAlign: TextAlign.center,

                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
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
              color: Theme.of(context).colorScheme.primaryContainer,

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
                  CurrencyFormatter.rupees(amountReceived),

                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,

                    fontSize: 34,

                    fontWeight: FontWeight.w600,

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

              if (PaymentMethodBreakdown.noteText(paymentMethodNote).isNotEmpty)
                _InfoRow(
                  label: 'Method note',
                  value: PaymentMethodBreakdown.noteText(paymentMethodNote),
                ),

              _InfoRow(
                label: 'Old balance',

                value: CurrencyFormatter.balanceAfter(previousBalance),
              ),

              _InfoRow(
                label: 'Settlement',

                value: CurrencyFormatter.rupees(settlementAmount),
              ),

              if (discount > 0)
                _InfoRow(
                  label: 'Discount',

                  value: CurrencyFormatter.rupees(discount),
                ),

              _InfoRow(
                label: 'Amount received',

                value: CurrencyFormatter.rupees(amountReceived),
              ),

              _InfoRow(
                label: 'New balance',

                value: CurrencyFormatter.balanceAfter(remainingBalance),

                valueColor: remainingBalance == 0
                    ? Theme.of(context).colorScheme.onSurfaceVariant
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

                        title: 'Signature',

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

                  fontWeight: FontWeight.w600,
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
