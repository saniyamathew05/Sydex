import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/customer.dart';
import '../../models/transaction.dart';
import '../../services/customer_service.dart';
import '../../services/salesman_visit_service.dart';
import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';

/// Owner overview built around the supplied LedgerPro desktop reference.
/// All financial/customer figures are read from the existing services.
class OwnerDashboard extends StatefulWidget {
  const OwnerDashboard({
    super.key,
    this.onOpenPayments,
    this.onOpenCustomers,
    this.onOpenVisitAudit,
    this.onOpenRoute,
    this.onAddCustomer,
    this.onRecordPurchase,
    this.userName = 'Owner',
  });

  final String userName;
  final VoidCallback? onOpenPayments;
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
  bool _refreshing = false;
  List<SalesmanDailyActivity> _todaySalesmanActivity = const [];
  Map<String, _SalesmanTodayPayments> _todaySalesmanPayments = {};
  String? _visitLoadError;

  Color get _ink => Theme.of(context).colorScheme.onSurface;
  Color get _navy => Theme.of(context).colorScheme.onSurface;
  static const _green = Color(0xFF0B5D3B);
  static const _greenLight = Color(0xFF8DCB9F);
  Color get _line => Theme.of(context).colorScheme.outlineVariant;
  Color get _muted => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _pageBackground => Theme.of(context).scaffoldBackgroundColor;
  static const _red = Color(0xFFD92D36);
  static const _orange = Color(0xFFEA8A26);
  static const _blue = Color(0xFF2F8F57);

  int get _newSalesmanPaymentCount => _todaySalesmanPayments.values.fold(
    0,
    (total, entry) => total + entry.paidCustomers.length,
  );

  @override
  void initState() {
    super.initState();
    CustomerService.dataVersion.addListener(_refresh);
    TransactionService.dataVersion.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    CustomerService.dataVersion.removeListener(_refresh);
    TransactionService.dataVersion.removeListener(_refresh);
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
        _todaySalesmanActivity =
            await SalesmanVisitService.loadTodaySalesmanActivity();
        final now = DateTime.now();
        final start = DateTime(now.year, now.month, now.day);
        final end = start.add(const Duration(days: 1));
        final rows = await Supabase.instance.client
            .from('payments')
            .select(
              'user_id, customer_id, amount_received, customers(business_name)',
            )
            .gte('transaction_date', start.toUtc().toIso8601String())
            .lt('transaction_date', end.toUtc().toIso8601String());
        final grouped = <String, _SalesmanTodayPayments>{};
        for (final row in rows) {
          final userId = row['user_id']?.toString();
          if (userId == null || userId.isEmpty) continue;
          final entry = grouped.putIfAbsent(userId, _SalesmanTodayPayments.new);
          entry.received += (row['amount_received'] as num?)?.toDouble() ?? 0;
          final customerName = row['customers'] is Map
              ? row['customers']['business_name']?.toString()
              : null;
          if (customerName != null && customerName.isNotEmpty) {
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
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
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
      case 'This week':
        return DateTimeRange(
          start: today.subtract(Duration(days: today.weekday - 1)),
          end: today.add(const Duration(days: 1)),
        );
      case 'This month':
        return DateTimeRange(
          start: DateTime(today.year, today.month),
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
      return !date.isBefore(range.start) && date.isBefore(range.end);
    }).toList();
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
    final count = _period == 'Today' ? 7 : (_period == 'This week' ? 7 : 7);
    final start = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: count - 1));
    final result = <_DayTotals>[];
    for (var i = 0; i < count; i++) {
      final day = start.add(Duration(days: i));
      final daily = _transactions
          .where((t) => _sameDay(t.transactionDate, day))
          .toList();
      final received = daily.fold<double>(
        0,
        (sum, t) => sum + t.amountReceived,
      );
      // For each customer, take only their last balance recorded on this day.
      final latestByCustomer = <String, PaymentTransaction>{};
      for (final t in daily) {
        final previous = latestByCustomer[t.customerId];
        if (previous == null ||
            t.transactionDate.isAfter(previous.transactionDate)) {
          latestByCustomer[t.customerId] = t;
        }
      }
      final pending = latestByCustomer.values.fold<double>(
        0,
        (sum, t) => sum + math.max(0, t.remainingBalance).toDouble(),
      );
      result.add(_DayTotals(day, received, pending));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final customers = CustomerService.customers;
    final receivable = TransactionService.getTotalMoneyToReceive(customers);
    final recentPayments =
        _transactions.where((t) => t.amountReceived > 0).toList()
          ..sort((a, b) => b.transactionDate.compareTo(a.transactionDate));
    final recent = recentPayments.take(5).toList();
    final locations = _locationDues(customers);
    final days = _chartDays();
    final periodTransactions = _periodTransactions();
    final periodReceived = periodTransactions.fold<double>(
      0,
      (total, transaction) => total + transaction.amountReceived,
    );
    final periodPurchases = periodTransactions
        .where((transaction) => transaction.transactionType == 'sale')
        .fold<double>(0, (total, transaction) => total + transaction.amount);
    return Container(
      color: _pageBackground,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final medium = constraints.maxWidth >= 650;
          final pad = wide ? 24.0 : 16.0;
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
                              value: 'This week',
                              child: Text('This week'),
                            ),
                            DropdownMenuItem(
                              value: 'This month',
                              child: Text('This month'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) setState(() => _period = value);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          tooltip: 'Refresh dashboard and view payments',
                          onPressed: _refreshing ? null : _load,
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
    return SizedBox(
      height: 44,
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
    final maxValue = days.fold<double>(
      1,
      (max, d) => math.max(max, math.max(d.received, d.pending)).toDouble(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(
          'Payments Overview',
          action: 'View All',
          onAction: widget.onOpenPayments,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _legend(_green, 'Received'),
            const SizedBox(width: 12),
            _legend(_greenLight, 'Pending'),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 132,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 27,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _axis(maxValue),
                      style: TextStyle(fontSize: 8, color: _muted),
                    ),
                    Text(
                      _axis(maxValue * .66),
                      style: TextStyle(fontSize: 8, color: _muted),
                    ),
                    Text(
                      _axis(maxValue * .33),
                      style: TextStyle(fontSize: 8, color: _muted),
                    ),
                    Text('0', style: TextStyle(fontSize: 8, color: _muted)),
                  ],
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: CustomPaint(
                        painter: _GridPainter(),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: days.map((d) {
                            final receivedHeight = (d.received / maxValue)
                                .clamp(0.0, 1.0)
                                .toDouble();
                            final pendingHeight = (d.pending / maxValue)
                                .clamp(0.0, 1.0)
                                .toDouble();
                            return Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Expanded(
                                      child: FractionallySizedBox(
                                        heightFactor: receivedHeight,
                                        alignment: Alignment.bottomCenter,
                                        child: Container(
                                          decoration: const BoxDecoration(
                                            color: _green,
                                            borderRadius: BorderRadius.vertical(
                                              top: Radius.circular(3),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: FractionallySizedBox(
                                        heightFactor: pendingHeight,
                                        alignment: Alignment.bottomCenter,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: _greenLight.withValues(
                                              alpha: .72,
                                            ),
                                            borderRadius:
                                                const BorderRadius.vertical(
                                                  top: Radius.circular(3),
                                                ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: days.map((d) {
                        return Expanded(
                          child: Center(
                            child: Text(
                              '${d.date.day} ${_month(d.date.month)}',
                              maxLines: 1,
                              style: TextStyle(fontSize: 8, color: _muted),
                            ),
                          ),
                        );
                      }).toList(),
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

  String _axis(double value) {
    if (value >= 100000) return '${(value / 1000).round()}K';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(0)}K';
    return value.round().toString();
  }

  Widget _recentPayments(List<PaymentTransaction> recent) => Column(
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
                  '+${_money(t.amountReceived)}',
                  style: TextStyle(
                    color: _green,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
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
            final planned = customers
                .where(
                  (customer) => locationSet.contains(
                    customer.location.trim().toLowerCase(),
                  ),
                )
                .length;
            final visited = activity.visitedCustomerCount;
            final todayPayments =
                _todaySalesmanPayments[activity.salesmanId] ??
                _SalesmanTodayPayments();
            final pending = customers
                .where(
                  (customer) => locationSet.contains(
                    customer.location.trim().toLowerCase(),
                  ),
                )
                .fold<double>(
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
                      style: const TextStyle(
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
                          'Received today: ${_money(todayPayments.received)}  •  Yet to receive: ${_money(pending)}',
                          style: TextStyle(color: _muted, fontSize: 9),
                        ),
                        if (todayPayments.paidCustomers.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Paid: ${todayPayments.paidCustomers.join(', ')}',
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
                            valueColor: const AlwaysStoppedAnimation(_green),
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

  Widget _locationWiseDues(Map<String, double> locations) {
    final entries = locations.entries.take(4).toList();
    final maxDue = entries.isEmpty ? 1.0 : entries.first.value;
    const colors = [_green, Color(0xFFFF6269), Color(0xFFFFBC43), _blue];
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

  Widget _legend(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: _muted, fontSize: 9.5)),
    ],
  );

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
  const _OwnerReceivableHero({required this.value, required this.customers});

  final String value;
  final int customers;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(22, 18, 18, 18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF073D28), Color(0xFF0B6A43)],
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
          ],
        ),
      ],
    ),
  );
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
                  color: color == _MetricColors.green
                      ? _OwnerDashboardState._green
                      : Theme.of(context).colorScheme.onSurfaceVariant,
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

class _MetricColors {
  static const green = Color(0xFF0B5D3B);
}

class _SalesmanTodayPayments {
  double received = 0;
  final Set<String> paidCustomers = <String>{};
}

class _DayTotals {
  const _DayTotals(this.date, this.received, this.pending);
  final DateTime date;
  final double received;
  final double pending;
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFEEF0F8)
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
