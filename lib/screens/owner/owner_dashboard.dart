import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/customer.dart';
import '../../models/transaction.dart';
import '../../services/customer_service.dart';
import '../../services/salesman_visit_service.dart';
import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';
import '../../services/supabase_pagination.dart';
import '../../services/notification_read_store.dart';
import '../../services/owner_display_settings.dart';
import '../../widgets/horizon_motion.dart';

/// Owner overview for the Sydex desktop experience.
/// All financial/customer figures are read from the existing services.
class OwnerDashboard extends StatefulWidget {
  const OwnerDashboard({
    super.key,
    this.onOpenPayments,
    this.onOpenNotifications,
    this.onOpenCustomers,
    this.onOpenVisitAudit,
    this.onOpenRoute,
    this.onAddCustomer,
    this.onRecordPurchase,
    this.userName = 'Owner',
  });

  final String userName;
  final VoidCallback? onOpenPayments;
  final VoidCallback? onOpenNotifications;
  final VoidCallback? onOpenCustomers;
  final VoidCallback? onOpenVisitAudit;
  final VoidCallback? onOpenRoute;
  final VoidCallback? onAddCustomer;
  final VoidCallback? onRecordPurchase;

  @override
  State<OwnerDashboard> createState() => _OwnerDashboardState();
}

class _OwnerDashboardState extends State<OwnerDashboard> {
  String _period = 'Today';
  DateTimeRange? _customPeriod;
  bool _refreshing = false;
  List<SalesmanDailyActivity> _todaySalesmanActivity = const [];
  Map<String, _SalesmanTodayPayments> _todaySalesmanPayments = {};
  List<Map<String, dynamic>> _ledgerEntries = const [];
  String? _visitLoadError;
  Set<String> _seenNotificationIds = <String>{};
  RealtimeChannel? _visitStatusChannel;

  Color get _ink => Theme.of(context).colorScheme.onSurface;
  Color get _navy => Theme.of(context).colorScheme.onSurface;
  Color get _green => Theme.of(context).colorScheme.primary;
  Color get _line => Theme.of(context).colorScheme.outlineVariant;
  Color get _muted => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _pageBackground => Theme.of(context).scaffoldBackgroundColor;
  static const _red = Color(0xFFD92D36);
  static const _orange = Color(0xFFEA8A26);
  static const _blue = Color(0xFF2F8F57);

  int get _newSalesmanPaymentCount => _todaySalesmanPayments.values
      .expand((entry) => entry.paymentIds)
      .where((id) => !_seenNotificationIds.contains(id))
      .length;

  @override
  void initState() {
    super.initState();
    CustomerService.dataVersion.addListener(_refresh);
    TransactionService.dataVersion.addListener(_refresh);
    _visitStatusChannel = Supabase.instance.client
        .channel('owner-dashboard-visit-statuses')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'salesman_customer_daily_status',
          callback: (_) => unawaited(_load()),
        )
        .subscribe();
    _load();
    NotificationReadStore.load().then((ids) {
      if (mounted) setState(() => _seenNotificationIds = ids);
    });
  }

  @override
  void dispose() {
    CustomerService.dataVersion.removeListener(_refresh);
    TransactionService.dataVersion.removeListener(_refresh);
    final channel = _visitStatusChannel;
    if (channel != null) {
      unawaited(Supabase.instance.client.removeChannel(channel));
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await CustomerService.loadCustomers();
      await TransactionService.loadCustomerBalances();
      await TransactionService.loadTransactions();
      try {
        final rows = await SupabasePagination.loadAll(
          (from, to) => Supabase.instance.client
              .from('ledger_entries')
              .select('id, customer_id, entry_type, amount, transaction_date')
              .order('id')
              .range(from, to),
        );
        _ledgerEntries = List<Map<String, dynamic>>.from(rows);
      } catch (error) {
        debugPrint('Could not load entries for dashboard calculations: $error');
        _ledgerEntries = const [];
      }
      try {
        _todaySalesmanActivity =
            await SalesmanVisitService.loadTodaySalesmanActivity();
        final now = DateTime.now();
        final start = DateTime(now.year, now.month, now.day);
        final end = start.add(const Duration(days: 1));
        final rows = await Supabase.instance.client
            .from('payments')
            .select(
              'user_id, customer_id, amount_received, is_bounced, customers(business_name)',
            )
            .gte('transaction_date', start.toUtc().toIso8601String())
            .lt('transaction_date', end.toUtc().toIso8601String());
        final grouped = <String, _SalesmanTodayPayments>{};
        for (final row in rows) {
          if (row['is_bounced'] == true) continue;
          final userId = row['user_id']?.toString();
          if (userId == null || userId.isEmpty) continue;
          final entry = grouped.putIfAbsent(userId, _SalesmanTodayPayments.new);
          final paymentId = row['id']?.toString();
          if (paymentId != null && paymentId.isNotEmpty) {
            entry.paymentIds.add(paymentId);
          }
          final customerId = row['customer_id']?.toString();
          entry.received += (row['amount_received'] as num?)?.toDouble() ?? 0;
          if (customerId != null && customerId.isNotEmpty) {
            entry.receivedByCustomer[customerId] =
                (entry.receivedByCustomer[customerId] ?? 0) +
                ((row['amount_received'] as num?)?.toDouble() ?? 0);
          }
          final customerName = row['customers'] is Map
              ? row['customers']['business_name']?.toString()
              : null;
          if (customerName != null && customerName.isNotEmpty) {
            if (customerId != null && customerId.isNotEmpty) {
              entry.customerNames[customerId] = customerName;
            }
            entry.paidCustomers.add(customerName);
          }
        }
        _todaySalesmanPayments = grouped;
        _visitLoadError = null;
      } catch (error) {
        // A missing optional visit table must not prevent the financial dashboard
        // from loading. Do not substitute sample visit data.
        _visitLoadError = error.toString();
        _todaySalesmanActivity = const [];
        _todaySalesmanPayments = {};
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _money(num value, {bool decimals = false}) => CurrencyFormatter.format(
    value,
    currencyCode: 'INR',
    decimals: decimals ? 2 : 0,
  );

  String _greeting() {
    final hour = DateTime.now().toLocal().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  bool _sameDay(DateTime a, DateTime b) {
    final local = a.toLocal();
    return local.year == b.year && local.month == b.month && local.day == b.day;
  }

  List<PaymentTransaction> get _transactions => TransactionService.transactions;

  DateTimeRange _selectedRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_period) {
      case '7 days':
      case 'This week':
        return DateTimeRange(
          start: today.subtract(const Duration(days: 6)),
          end: today.add(const Duration(days: 1)),
        );
      case '30 days':
      case 'This month':
        return DateTimeRange(
          start: today.subtract(const Duration(days: 29)),
          end: today.add(const Duration(days: 1)),
        );
      case 'Custom':
        return _customPeriod ??
            DateTimeRange(
              start: today,
              end: today.add(const Duration(days: 1)),
            );
      default:
        return DateTimeRange(
          start: today,
          end: today.add(const Duration(days: 1)),
        );
    }
  }

  List<PaymentTransaction> _periodTransactions() {
    final range = _selectedRange();
    return _transactions.where((transaction) {
      final date = transaction.transactionDate.toLocal();
      return !transaction.isBounced &&
          !date.isBefore(range.start) &&
          date.isBefore(range.end);
    }).toList();
  }

  List<Map<String, dynamic>> _periodLedgerEntries() {
    final range = _selectedRange();
    return _ledgerEntries
        .where((entry) {
          final date = DateTime.tryParse(
            entry['transaction_date']?.toString() ?? '',
          )?.toLocal();
          return date != null &&
              !date.isBefore(range.start) &&
              date.isBefore(range.end);
        })
        .toList(growable: false);
  }

  int get _locationCount => CustomerService.customers
      .map((c) => c.location.trim().toLowerCase())
      .where((location) => location.isNotEmpty)
      .toSet()
      .length;

  Map<String, double> _locationDues(List<Customer> customers) {
    final totals = <String, double>{};
    for (final customer in customers) {
      final name = customer.location.trim().isEmpty
          ? 'Unassigned'
          : customer.location.trim();
      totals[name] =
          (totals[name] ?? 0) +
          math.max(0, TransactionService.getCustomerBalance(customer.id));
    }
    return Map.fromEntries(
      totals.entries.where((e) => e.value > 0).toList()
        ..sort((a, b) => b.value.compareTo(a.value)),
    );
  }

  List<_DayTotals> _chartDays() {
    final now = DateTime.now();
    // Render every calendar day in the current month so the overview remains
    // a stable monthly graph even when there are no collections yet.
    final count = DateTime(now.year, now.month + 1, 0).day;
    final start = DateTime(now.year, now.month);
    final result = <_DayTotals>[];
    for (var i = 0; i < count; i++) {
      final day = start.add(Duration(days: i));
      final received = _transactions
          .where((t) => !t.isBounced && _sameDay(t.transactionDate, day))
          .fold<double>(0, (sum, t) => sum + t.actualAmountReceived);
      final balancesAtEndOfDay = <String, double>{
        for (final customer in CustomerService.customers)
          customer.id: customer.openingBalance,
      };
      for (final entry in _ledgerEntries) {
        final entryDate = DateTime.tryParse(
          entry['transaction_date']?.toString() ?? '',
        )?.toLocal();
        if (entryDate == null ||
            DateTime(
              entryDate.year,
              entryDate.month,
              entryDate.day,
            ).isAfter(day)) {
          continue;
        }
        final customerId = entry['customer_id']?.toString();
        if (customerId == null || !balancesAtEndOfDay.containsKey(customerId)) {
          continue;
        }
        final type = entry['entry_type']?.toString().toLowerCase();
        final amount = (entry['amount'] as num?)?.toDouble() ?? 0;
        if (type == 'purchase' || type == 'sale' || type == 'bounced_check') {
          balancesAtEndOfDay[customerId] =
              balancesAtEndOfDay[customerId]! + amount;
        } else if (type == 'payment' ||
            type == 'return' ||
            type == 'sales_return') {
          balancesAtEndOfDay[customerId] =
              balancesAtEndOfDay[customerId]! - amount;
        }
      }
      final pending = balancesAtEndOfDay.values.fold<double>(
        0,
        (sum, balance) => sum + math.max(0, balance).toDouble(),
      );
      result.add(_DayTotals(day, received, pending));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final customers = CustomerService.customers;
    final receivable = TransactionService.getTotalMoneyToReceive(customers);
    final overdue = _overdueAmount(customers);
    final recentPayments =
        _transactions.where((t) => t.actualAmountReceived > 0).toList()..sort(
          (a, b) => (b.createdAt ?? b.transactionDate).compareTo(
            a.createdAt ?? a.transactionDate,
          ),
        );
    final recent = recentPayments.take(5).toList();
    final locations = _locationDues(customers);
    final days = _chartDays();
    final periodTransactions = _periodTransactions();
    final periodReceived = periodTransactions.fold<double>(
      0,
      (total, transaction) => total + transaction.actualAmountReceived,
    );
    final periodPurchases = _periodLedgerEntries()
        .where((entry) => entry['entry_type']?.toString() == 'purchase')
        .fold<double>(
          0,
          (total, entry) =>
              total + ((entry['amount'] as num?)?.toDouble() ?? 0),
        );
    return Container(
      color: _pageBackground,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final medium = constraints.maxWidth >= 650;
          final pad = wide ? 24.0 : 16.0;
          if (!medium) {
            return _buildMobileDashboard(
              customers: customers,
              receivable: receivable,
              overdue: overdue,
              recent: recent,
              locations: locations,
              days: days,
              periodReceived: periodReceived,
              periodPurchases: periodPurchases,
              paymentCount: periodTransactions.length,
            );
          }
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, wide ? 18 : 16, pad, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: widget.onOpenCustomers,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: _surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _line),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search_rounded, color: _muted, size: 20),
                        const SizedBox(width: 10),
                        Text(
                          'Search customers, locations...',
                          style: TextStyle(color: _muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_greeting()}, ${widget.userName} 👋',
                            style: TextStyle(
                              color: _ink,
                              fontSize: wide ? 23 : 21,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.45,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Here’s your business overview for today.',
                            style: TextStyle(color: _muted, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      decoration: BoxDecoration(
                        color: _surface,
                        border: Border.all(color: _line),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _period,
                          isDense: true,
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 16,
                          ),
                          style: TextStyle(color: _ink, fontSize: 11),
                          items: const [
                            DropdownMenuItem(
                              value: 'Today',
                              child: Text('Today'),
                            ),
                            DropdownMenuItem(
                              value: '7 days',
                              child: Text('7 days'),
                            ),
                            DropdownMenuItem(
                              value: '30 days',
                              child: Text('30 days'),
                            ),
                            DropdownMenuItem(
                              value: 'Custom',
                              child: Text('Custom'),
                            ),
                            DropdownMenuItem(
                              value: 'This week',
                              child: Text('This week'),
                            ),
                            DropdownMenuItem(
                              value: 'This month',
                              child: Text('This month'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == 'Custom') {
                              showDateRangePicker(
                                context: context,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now().add(
                                  const Duration(days: 365),
                                ),
                                initialDateRange: _customPeriod,
                              ).then((range) {
                                if (!mounted || range == null) return;
                                setState(() {
                                  _customPeriod = range;
                                  _period = 'Custom';
                                });
                              });
                            } else if (value != null) {
                              setState(() => _period = value);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          tooltip: 'Notifications',
                          onPressed: widget.onOpenNotifications,
                          icon: _refreshing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.notifications_none_rounded,
                                  color: _navy,
                                  size: 21,
                                ),
                        ),
                        if (_newSalesmanPaymentCount > 0)
                          Positioned(
                            right: 5,
                            top: 2,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _red,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '$_newSalesmanPaymentCount',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (wide)
                  SizedBox(
                    height: 174,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 5,
                          child: _OwnerReceivableHero(
                            value: _money(receivable),
                            customers: customers.length,
                            overdue: _money(overdue),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 7,
                          child: GridView.count(
                            crossAxisCount: 3,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            crossAxisSpacing: 10,
                            childAspectRatio: 1.42,
                            children: [
                              _MetricCard(
                                title: 'Today’s collections',
                                value: _money(periodReceived),
                                foot: '${periodTransactions.length} payments',
                                icon: Icons.download_rounded,
                                color: _green,
                                bg: const Color(0xFFE5F4E8),
                              ),
                              _MetricCard(
                                title: 'New purchases',
                                value: _money(periodPurchases),
                                foot: 'In selected period',
                                icon: Icons.shopping_cart_outlined,
                                color: _orange,
                                bg: const Color(0xFFFFF0DE),
                              ),
                              _MetricCard(
                                title: 'Active customers',
                                value: '${customers.length}',
                                foot: 'Across $_locationCount locations',
                                icon: Icons.groups_2_outlined,
                                color: _blue,
                                bg: const Color(0xFFE8F4E9),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                else ...[
                  _OwnerReceivableHero(
                    value: _money(receivable),
                    customers: customers.length,
                    overdue: _money(overdue),
                  ),
                  const SizedBox(height: 10),
                  GridView.count(
                    crossAxisCount: medium ? 3 : 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 1.65,
                    children: [
                      _MetricCard(
                        title: 'Collections',
                        value: _money(periodReceived),
                        foot: '${periodTransactions.length} payments',
                        icon: Icons.download_rounded,
                        color: _green,
                        bg: const Color(0xFFE5F4E8),
                      ),
                      _MetricCard(
                        title: 'New purchases',
                        value: _money(periodPurchases),
                        foot: 'In selected period',
                        icon: Icons.shopping_cart_outlined,
                        color: _orange,
                        bg: const Color(0xFFFFF0DE),
                      ),
                      _MetricCard(
                        title: 'Active customers',
                        value: '${customers.length}',
                        foot: 'Across $_locationCount locations',
                        icon: Icons.groups_2_outlined,
                        color: _blue,
                        bg: const Color(0xFFE8F4E9),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _quickAction(
                      Icons.person_add_alt_1_rounded,
                      'Add customer',
                      widget.onAddCustomer,
                    ),
                    _quickAction(
                      Icons.shopping_cart_outlined,
                      'Record purchase',
                      widget.onRecordPurchase,
                    ),
                    _quickAction(
                      Icons.route_rounded,
                      'Create route',
                      widget.onOpenRoute,
                    ),
                    _quickAction(
                      Icons.receipt_long_rounded,
                      'View ledger',
                      widget.onOpenPayments,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 6,
                        child: _panel(child: _paymentsChart(days)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 4,
                        child: _panel(child: _recentPayments(recent)),
                      ),
                    ],
                  )
                else ...[
                  _panel(child: _paymentsChart(days)),
                  const SizedBox(height: 12),
                  _panel(child: _recentPayments(recent)),
                ],
                const SizedBox(height: 14),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 6,
                        child: _panel(
                          child: _salesmanActivity(
                            _todaySalesmanActivity,
                            customers,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 4,
                        child: _panel(child: _locationWiseDues(locations)),
                      ),
                    ],
                  )
                else ...[
                  _panel(
                    child: _salesmanActivity(_todaySalesmanActivity, customers),
                  ),
                  const SizedBox(height: 12),
                  _panel(child: _locationWiseDues(locations)),
                ],
                if (_visitLoadError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Salesman activity is unavailable until visit tracking is configured.',
                    style: TextStyle(color: _muted, fontSize: 10),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMobileDashboard({
    required List<Customer> customers,
    required double receivable,
    required double overdue,
    required List<PaymentTransaction> recent,
    required Map<String, double> locations,
    required List<_DayTotals> days,
    required double periodReceived,
    required double periodPurchases,
    required int paymentCount,
  }) {
    return RefreshIndicator(
      onRefresh: _load,
      color: _green,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _green,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.account_balance_wallet_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sydex',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Business overview',
                      style: TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Search customers',
                onPressed: widget.onOpenCustomers,
                icon: Icon(Icons.search_rounded, color: _ink),
              ),
              IconButton(
                tooltip: 'Notifications',
                onPressed: widget.onOpenNotifications,
                icon: Icon(Icons.notifications_none_rounded, color: _ink),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _OwnerReceivableHero(
            value: _money(receivable),
            customers: customers.length,
            overdue: _money(overdue),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _mobileMetric(
                  'Collected today',
                  _money(periodReceived),
                  Icons.download_rounded,
                  _green,
                  const Color(0xFFE5F4E8),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _mobileMetric(
                  'New purchases',
                  _money(periodPurchases),
                  Icons.shopping_cart_outlined,
                  _orange,
                  const Color(0xFFFFF0DE),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Quick actions',
            style: TextStyle(
              color: _ink,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _mobileAction(
                Icons.person_add_alt_1_rounded,
                'Customer',
                widget.onAddCustomer,
              ),
              _mobileAction(
                Icons.payments_outlined,
                'Payment',
                widget.onOpenPayments,
              ),
              _mobileAction(
                Icons.shopping_cart_outlined,
                'Purchase',
                widget.onRecordPurchase,
              ),
              _mobileAction(Icons.route_rounded, 'Route', widget.onOpenRoute),
            ],
          ),
          const SizedBox(height: 20),
          _mobileSectionHeader(
            'Payments overview',
            '$_period · $paymentCount payments',
          ),
          const SizedBox(height: 8),
          _panel(child: _paymentsChart(days)),
          const SizedBox(height: 18),
          _mobileSectionHeader(
            'Recent payments',
            'View all',
            onTap: widget.onOpenPayments,
          ),
          const SizedBox(height: 8),
          _panel(child: _recentPayments(recent)),
          const SizedBox(height: 18),
          _mobileSectionHeader(
            'Salesman activity',
            'View map',
            onTap: widget.onOpenVisitAudit,
          ),
          const SizedBox(height: 8),
          _panel(child: _salesmanActivity(_todaySalesmanActivity, customers)),
          const SizedBox(height: 18),
          _mobileSectionHeader('Location-wise due', 'View all'),
          const SizedBox(height: 8),
          _panel(
            child: _locationWiseDues(
              Map<String, double>.fromEntries(locations.entries.take(3)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileMetric(
    String label,
    String value,
    IconData icon,
    Color color,
    Color bg,
  ) => Container(
    height: 92,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 18),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: _ink,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(label, style: TextStyle(color: _muted, fontSize: 11)),
      ],
    ),
  );

  Widget _mobileAction(IconData icon, String label, VoidCallback? onTap) =>
      SizedBox(
        width: 70,
        child: HorizonPressable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _surface,
                  border: Border.all(color: _line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: _green, size: 20),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _mobileSectionHeader(
    String title,
    String action, {
    VoidCallback? onTap,
  }) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: TextStyle(
            color: _ink,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      GestureDetector(
        onTap: onTap,
        child: Text(
          action,
          style: TextStyle(
            color: _green,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );

  double _overdueAmount(List<Customer> customers) {
    final today = DateTime.now();
    final latestByCustomer = <String, DateTime>{};
    for (final entry in _ledgerEntries) {
      final id = entry['customer_id']?.toString();
      final date = DateTime.tryParse(
        entry['transaction_date']?.toString() ?? '',
      )?.toLocal();
      if (id == null || date == null) continue;
      final current = latestByCustomer[id];
      if (current == null || date.isAfter(current)) latestByCustomer[id] = date;
    }
    return customers.fold<double>(0, (total, customer) {
      final balance = TransactionService.getCustomerBalance(customer.id);
      final last = latestByCustomer[customer.id];
      final overdue =
          balance > 0 &&
          last != null &&
          DateTime(
            last.year,
            last.month,
            last.day,
          ).isBefore(DateTime(today.year, today.month, today.day));
      return total + (overdue ? balance : 0);
    });
  }

  Widget _panel({required Widget child}) => Container(
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _line),
    ),
    padding: const EdgeInsets.all(14),
    child: child,
  );

  Widget _quickAction(IconData icon, String label, VoidCallback? onPressed) {
    return HorizonPressable(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 44,
        child: IgnorePointer(
          child: OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18, color: _green),
            label: Text(label),
            style: OutlinedButton.styleFrom(
              foregroundColor: _ink,
              backgroundColor: _surface,
              side: BorderSide(color: _line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
          ),
        ),
      ),
    );
  }

  Widget _panelHeader(
    String title, {
    String action = '',
    VoidCallback? onAction,
  }) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: TextStyle(
            color: _ink,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      ),
      if (action.isNotEmpty)
        TextButton(
          onPressed: onAction,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(30, 24),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            action,
            style: TextStyle(
              color: _green,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
    ],
  );

  Widget _paymentsChart(List<_DayTotals> days) {
    final receivedTotal = days.fold<double>(
      0,
      (total, day) => total + day.received,
    );
    final outstanding = days.isEmpty ? 0.0 : days.last.pending;
    final maxReceived = days.fold<double>(
      1,
      (max, day) => math.max(max, day.received).toDouble(),
    );
    final labelIndexes = <int>{
      if (days.isNotEmpty) 0,
      if (days.length > 2) days.length ~/ 2,
      if (days.length > 1) days.length - 1,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(
          'Payments Overview',
          action: 'View All',
          onAction: widget.onOpenPayments,
        ),
        const SizedBox(height: 4),
        Text(
          'Daily collections • ${days.isEmpty ? '' : '${_month(days.first.date.month)} ${days.first.date.year}'}',
          style: TextStyle(color: _muted, fontSize: 10),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _chartMetric(
                icon: Icons.south_west_rounded,
                label: 'Collected',
                value: _money(receivedTotal),
                color: _green,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _chartMetric(
                icon: Icons.account_balance_wallet_outlined,
                label: 'Outstanding',
                value: _money(outstanding),
                color: _muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 176,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 34,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _axis(maxReceived),
                        style: TextStyle(fontSize: 8, color: _muted),
                      ),
                      Text(
                        _axis(maxReceived * .5),
                        style: TextStyle(fontSize: 8, color: _muted),
                      ),
                      Text('0', style: TextStyle(fontSize: 8, color: _muted)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: RepaintBoundary(
                        child: SizedBox.expand(
                          child: CustomPaint(
                            painter: _DailyCollectionLinePainter(
                              values: days
                                  .map((day) => day.received)
                                  .toList(growable: false),
                              lineColor: _green,
                              gridColor: _line,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    SizedBox(
                      height: 15,
                      child: Row(
                        children: List.generate(
                          days.length,
                          (index) => Expanded(
                            child: Center(
                              child: Text(
                                labelIndexes.contains(index)
                                    ? days[index].date.day.toString()
                                    : '',
                                maxLines: 1,
                                style: TextStyle(fontSize: 8, color: _muted),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chartMetric({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: _muted, fontSize: 9)),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  String _axis(double value) {
    if (value >= 100000) return '${(value / 1000).round()}K';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(0)}K';
    return value.round().toString();
  }

  Widget _recentPayments(List<PaymentTransaction> recent) => ValueListenableBuilder<bool>(
    valueListenable: OwnerDisplaySettings.showRecentPayments,
    builder: (context, visible, _) => visible ? Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _panelHeader(
        'Recent Payments',
        action: 'View All',
        onAction: widget.onOpenPayments,
      ),
      const SizedBox(height: 7),
      if (recent.isEmpty) ...[
        SizedBox(
          height: 110,
          child: Center(
            child: Text(
              'No payments recorded yet',
              style: TextStyle(color: _muted, fontSize: 11),
            ),
          ),
        ),
      ] else
        ...recent.map(
          (t) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF183D2D)
                      : const Color(0xFFDDF3E5),
                  child: Text(
                    t.customerName.isEmpty
                        ? '?'
                        : t.customerName[0].toUpperCase(),
                    style: TextStyle(
                      color: _green,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.customerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _ink,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '+${_money(t.actualAmountReceived)}',
                  style: TextStyle(
                    color: _green,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  t.isBounced
                      ? Icons.error_outline_rounded
                      : Icons.verified_rounded,
                  size: 13,
                  color: t.isBounced ? _red : _green,
                ),
                const SizedBox(width: 7),
                SizedBox(
                  width: 48,
                  child: Text(
                    _relativeTime(t.transactionDate),
                    textAlign: TextAlign.right,
                    style: TextStyle(color: _muted, fontSize: 9),
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
    ) : const SizedBox.shrink(),
  );

  Widget _salesmanActivity(
    List<SalesmanDailyActivity> activities,
    List<Customer> customers,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(
          'Today’s Salesman Activity',
          action: 'View Map',
          onAction: widget.onOpenVisitAudit,
        ),
        const SizedBox(height: 12),
        if (activities.isEmpty)
          Text(
            'No salesman accounts found.',
            style: TextStyle(color: _muted, fontSize: 10.5),
          )
        else
          ...activities.indexed.expand((entry) {
            final index = entry.$1;
            final activity = entry.$2;
            final routeLocations = activity.routeLocations;
            final locationSet = routeLocations
                .map((location) => location.trim().toLowerCase())
                .toSet();
            final assignedIds = activity.assignedCustomerIds.isNotEmpty
                ? activity.assignedCustomerIds
                : customers
                      .where(
                        (customer) => locationSet.contains(
                          customer.location.trim().toLowerCase(),
                        ),
                      )
                      .map((customer) => customer.id)
                      .toSet();
            final assignedCustomers = customers
                .where((customer) => assignedIds.contains(customer.id))
                .toList();
            final planned = assignedCustomers.length;
            final visited = activity.visitedCustomerCount;
            final todayPayments =
                _todaySalesmanPayments[activity.salesmanId] ??
                _SalesmanTodayPayments();
            // Payment activity must be limited to this salesman’s current
            // assignment. Historical payments from other routes should not
            // inflate today’s route-level paid indicator.
            final routePayments = todayPayments.forCustomers(assignedIds);
            final pending = assignedCustomers.fold<double>(
              0,
              (total, customer) =>
                  total +
                  math.max(
                    0,
                    TransactionService.getCustomerBalance(customer.id),
                  ),
            );
            final progress = planned == 0
                ? 0.0
                : (visited / planned).clamp(0.0, 1.0).toDouble();
            final routeLabel = routeLocations.isEmpty
                ? 'No route assigned'
                : [
                    if (activity.routeName?.trim().isNotEmpty == true)
                      activity.routeName!.trim(),
                    routeLocations.join(' → '),
                  ].join(' · ');
            return [
              if (index > 0) Divider(height: 18, color: _line),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor:
                        Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF183D2D)
                        : const Color(0xFFDDF3E5),
                    child: Text(
                      activity.salesmanName.trim().isEmpty
                          ? 'S'
                          : activity.salesmanName.trim()[0].toUpperCase(),
                      style: TextStyle(
                        color: _green,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          activity.salesmanName,
                          style: TextStyle(
                            color: _ink,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          routeLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: _muted, fontSize: 9.5),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          planned == 0
                              ? '$visited visits recorded today'
                              : '$visited/$planned customers visited today',
                          style: TextStyle(color: _muted, fontSize: 9),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Received today: ${_money(routePayments.received)}  •  Yet to receive: ${_money(pending)}',
                          style: TextStyle(color: _muted, fontSize: 9),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 5,
                          runSpacing: 4,
                          children: [
                            _activityChip(
                              'Paid ${routePayments.paidCustomers.length}',
                              _green,
                            ),
                            _activityChip(
                              'Pending ${math.max(0, planned - visited)}',
                              _orange,
                            ),
                            _activityChip(
                              'Refused ${activity.refusedCustomerCount}',
                              _red,
                            ),
                          ],
                        ),
                        if (planned > visited) ...[
                          const SizedBox(height: 3),
                          Text(
                            '${planned - visited} customer${planned - visited == 1 ? '' : 's'} not visited yet',
                            style: TextStyle(color: _orange, fontSize: 9),
                          ),
                        ],
                        if (visited > 0 && routePayments.received == 0) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Visits recorded with no collection yet',
                            style: TextStyle(color: _muted, fontSize: 9),
                          ),
                        ],
                        if (routePayments.paidCustomers.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Paid: ${routePayments.paidCustomers.join(', ')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: _green, fontSize: 9),
                          ),
                        ],
                        const SizedBox(height: 5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 6,
                            backgroundColor:
                                Theme.of(context).brightness == Brightness.dark
                                ? Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest
                                : const Color(0xFFECEBFA),
                            valueColor: AlwaysStoppedAnimation(_green),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(progress * 100).round()}%',
                    style: TextStyle(
                      color: _ink,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ];
          }),
      ],
    );
  }

  Widget _activityChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 8.5,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _locationWiseDues(Map<String, double> locations) {
    final entries = locations.entries.take(4).toList();
    final maxDue = entries.isEmpty ? 1.0 : entries.first.value;
    final colors = [_green, Color(0xFFFF6269), Color(0xFFFFBC43), _blue];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(
          'Location Wise Due',
          action: 'View All',
          onAction: widget.onOpenCustomers,
        ),
        const SizedBox(height: 8),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              'No outstanding balances by location.',
              style: TextStyle(color: _muted, fontSize: 10),
            ),
          )
        else
          ...List.generate(entries.length, (i) {
            final e = entries[i];
            final color = colors[i % colors.length];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _ink, fontSize: 10),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 70,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (e.value / maxDue).clamp(0.0, 1.0).toDouble(),
                        minHeight: 6,
                        backgroundColor: color.withValues(alpha: .12),
                        valueColor: AlwaysStoppedAnimation(
                          color.withValues(alpha: .7),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _money(e.value),
                    style: TextStyle(
                      color: i == 0 ? _red : (i == 1 ? _orange : _ink),
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  String _relativeTime(DateTime date) {
    final difference = DateTime.now().difference(date);

    if (difference.isNegative || difference.inMinutes < 1) {
      return 'Just now';
    }

    if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min ago';
    }

    if (difference.inHours < 24) {
      return '${difference.inHours} hour${difference.inHours == 1 ? '' : 's'} ago';
    }

    if (difference.inDays == 1) {
      return 'Yesterday';
    }

    return '${date.day} ${_month(date.month)}';
  }

  String _month(int month) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][month - 1];
}

class _OwnerReceivableHero extends StatelessWidget {
  const _OwnerReceivableHero({
    required this.value,
    required this.customers,
    required this.overdue,
  });

  final String value;
  final int customers;
  final String overdue;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 18, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color.lerp(primary, Colors.black, .26)!, primary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -8,
            top: -12,
            child: Icon(Icons.eco_rounded, size: 104, color: Colors.white12),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    color: Colors.white,
                    size: 20,
                  ),
                  SizedBox(width: 9),
                  Text(
                    'Total receivable',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(
                    Icons.visibility_outlined,
                    color: Colors.white70,
                    size: 20,
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                'Across $customers customers',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 6),
              Text(
                'Overdue: $overdue',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.foot,
    required this.icon,
    required this.color,
    required this.bg,
  });
  final String title;
  final String value;
  final String foot;
  final IconData icon;
  final Color color;
  final Color bg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark
          ? color.withValues(alpha: .16)
          : bg.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: color.withValues(alpha: .08)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              width: 29,
              height: 29,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 17),
            ),
          ],
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -.4,
            ),
          ),
        ),
        Text(
          foot,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 8.5,
          ),
        ),
      ],
    ),
  );
}

class _SalesmanTodayPayments {
  double received = 0;
  final Set<String> paymentIds = <String>{};
  final Set<String> paidCustomers = <String>{};
  final Map<String, double> receivedByCustomer = <String, double>{};
  final Map<String, String> customerNames = <String, String>{};

  _SalesmanTodayPayments forCustomers(Set<String> customerIds) {
    final filtered = _SalesmanTodayPayments();
    for (final id in customerIds) {
      final amount = receivedByCustomer[id];
      if (amount != null) filtered.received += amount;
      final name = customerNames[id];
      if (name != null) filtered.paidCustomers.add(name);
    }
    return filtered;
  }
}

class _DayTotals {
  const _DayTotals(this.date, this.received, this.pending);
  final DateTime date;
  final double received;
  final double pending;
}

class _DailyCollectionLinePainter extends CustomPainter {
  const _DailyCollectionLinePainter({
    required this.values,
    required this.lineColor,
    required this.gridColor,
  });

  final List<double> values;
  final Color lineColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.isEmpty) return;
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: .65)
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final maxValue = values.fold<double>(1, math.max);
    final step = values.length == 1 ? 0.0 : size.width / (values.length - 1);
    final points = List<Offset>.generate(values.length, (index) {
      final progress = (values[index] / maxValue).clamp(0.0, 1.0);
      return Offset(index * step, size.height - progress * size.height);
    });
    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index++) {
      final previous = points[index - 1];
      final point = points[index];
      final midpoint = (previous.dx + point.dx) / 2;
      linePath.cubicTo(
        midpoint,
        previous.dy,
        midpoint,
        point.dy,
        point.dx,
        point.dy,
      );
    }

    final fillPath = Path.from(linePath)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..color = lineColor.withValues(alpha: .12)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final dotPaint = Paint()..color = lineColor;
    for (final point in points) {
      canvas.drawCircle(point, 2.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _DailyCollectionLinePainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.gridColor != gridColor;
}
