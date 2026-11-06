import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/transaction.dart';

import '../../services/customer_service.dart';

import '../../services/transaction_service.dart';

import '../../services/currency_formatter.dart';

class OwnerReportsScreen extends StatelessWidget {
  const OwnerReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: CustomerService.dataVersion,

      builder: (context, customerVersion, _) {
        return ValueListenableBuilder<int>(
          valueListenable: TransactionService.dataVersion,

          builder: (context, transactionVersion, _) {
            return _ReportsContent();
          },
        );
      },
    );
  }
}

class _ReportsContent extends StatefulWidget {
  const _ReportsContent();

  @override
  State<_ReportsContent> createState() => _ReportsContentState();
}

class _ReportsContentState extends State<_ReportsContent> {
  String _selectedPeriod = '7 Days';

  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final customers = CustomerService.customers;

    final transactions = TransactionService.transactions
        .where((transaction) => !transaction.isBounced)
        .toList(growable: false);

    final chartData = _buildChartData(transactions, _selectedPeriod);

    final totalCollected = _getTotalCollected(transactions);

    final totalPayments = transactions.length;

    final averagePayment = totalPayments == 0
        ? 0.0
        : totalCollected / totalPayments;

    final outstanding = customers.fold<double>(0.0, (sum, customer) {
      final balance = TransactionService.getCustomerBalance(customer.id);
      return sum + (balance > 0 ? balance : 0);
    });

    final todayCollected = TransactionService.getCollectedToday();

    final todayPayments = TransactionService.getPaymentsToday();

    final topCustomers = _getTopCustomers(transactions);

    final outstandingCustomers = customers
        .where(
          (customer) => TransactionService.getCustomerBalance(customer.id) > 0,
        )
        .toList();

    outstandingCustomers.sort((a, b) {
      final balanceA = TransactionService.getCustomerBalance(a.id);

      final balanceB = TransactionService.getCustomerBalance(b.id);

      return balanceB.compareTo(balanceA);
    });

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,

      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshData,

          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 600;

              return ListView(
                padding: EdgeInsets.fromLTRB(
                  compact ? 12 : 24,

                  compact ? 14 : 24,

                  compact ? 12 : 24,

                  40,
                ),

                children: [
                  _buildHeader(context),

                  const SizedBox(height: 24),

                  _buildSummaryCards(
                    totalCollected: totalCollected,

                    totalPayments: totalPayments,

                    averagePayment: averagePayment,

                    outstanding: outstanding,
                  ),

                  const SizedBox(height: 28),

                  _buildCollectionChart(chartData),

                  const SizedBox(height: 24),

                  _buildTodayCard(todayCollected, todayPayments),

                  const SizedBox(height: 24),

                  _buildPaymentActivity(transactions),

                  const SizedBox(height: 24),

                  _buildTopCustomers(topCustomers),

                  const SizedBox(height: 24),

                  _buildOutstandingCustomers(outstandingCustomers),

                  const SizedBox(height: 24),

                  _buildRecentPayments(transactions),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              Text(
                'Business Reports',

                style: TextStyle(
                  fontSize: 30,

                  fontWeight: FontWeight.w800,

                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),

              const SizedBox(height: 6),

              Text(
                'Track collections, payments and outstanding balances.',

                style: TextStyle(
                  fontSize: 14,

                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),

        IconButton(
          tooltip: 'Refresh',

          onPressed: _refreshData,

          icon: Icon(
            Icons.refresh_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCards({
    required double totalCollected,

    required int totalPayments,

    required double averagePayment,

    required double outstanding,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 850;

        final cards = [
          _SummaryCard(
            title: 'Total Collected',

            value: _formatMoney(totalCollected),

            icon: Icons.account_balance_wallet_rounded,

            iconColor: const Color(0xFF087F6A),

            backgroundColor: const Color(0xFFE4F5F0),
          ),

          _SummaryCard(
            title: 'Total Payments',

            value: totalPayments.toString(),

            icon: Icons.receipt_long_rounded,

            iconColor: const Color(0xFF2563EB),

            backgroundColor: const Color(0xFFE8F0FF),
          ),

          _SummaryCard(
            title: 'Average Payment',

            value: _formatMoney(averagePayment),

            icon: Icons.payments_rounded,

            iconColor: Theme.of(context).colorScheme.primary,

            backgroundColor: const Color(0xFFE8F5EB),
          ),

          _SummaryCard(
            title: 'Outstanding',

            value: _formatMoney(outstanding),

            icon: Icons.pending_actions_rounded,

            iconColor: const Color(0xFFEA580C),

            backgroundColor: const Color(0xFFFFEEE4),
          ),
        ];

        if (isWide) {
          return Row(
            children: [
              Expanded(child: cards[0]),

              const SizedBox(width: 14),

              Expanded(child: cards[1]),

              const SizedBox(width: 14),

              Expanded(child: cards[2]),

              const SizedBox(width: 14),

              Expanded(child: cards[3]),
            ],
          );
        }

        return GridView.builder(
          shrinkWrap: true,

          physics: const NeverScrollableScrollPhysics(),

          itemCount: cards.length,

          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,

            crossAxisSpacing: 10,

            mainAxisSpacing: 10,

            childAspectRatio: constraints.maxWidth < 380 ? 1.35 : 1.55,
          ),

          itemBuilder: (context, index) {
            return cards[index];
          },
        );
      },
    );
  }

  Widget _buildCollectionChart(List<_ChartPoint> points) {
    final total = points.fold<double>(0, (sum, point) => sum + point.value);

    return Container(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 14 : 24),

      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,

        borderRadius: BorderRadius.circular(20),

        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),

        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.035),

            blurRadius: 18,

            offset: const Offset(0, 7),
          ),
        ],
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Text(
                      'Collection Overview',

                      style: TextStyle(
                        fontSize: 20,

                        fontWeight: FontWeight.w800,

                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),

                    const SizedBox(height: 5),

                    Text(
                      'Payment collections over time',

                      style: TextStyle(
                        fontSize: 13,

                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),

              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),

                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,

                  borderRadius: BorderRadius.circular(12),
                ),

                child: Wrap(
                  spacing: 2,

                  runSpacing: 2,

                  children: [
                    _periodButton('7 Days'),

                    _periodButton('30 Days'),

                    _periodButton('12 Months'),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 22),

          Row(
            children: [
              Container(
                width: 42,

                height: 42,

                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Theme.of(context).colorScheme.surfaceContainerHigh
                      : const Color(0xFFE4F5F0),

                  borderRadius: BorderRadius.circular(12),
                ),

                child: const Icon(
                  Icons.trending_up_rounded,

                  color: Color(0xFF087F6A),
                ),
              ),

              const SizedBox(width: 12),

              Column(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  Text(
                    _formatMoney(total),

                    style: TextStyle(
                      fontSize: 21,

                      fontWeight: FontWeight.w800,

                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),

                  Text(
                    'Collected in $_selectedPeriod',

                    style: TextStyle(
                      fontSize: 12,

                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 20),

          SizedBox(
            height: 280,

            width: double.infinity,

            child: points.isEmpty
                ? _buildEmptyChart()
                : CustomPaint(
                    painter: _CollectionChartPainter(
                      points: points,
                      lineColor: Theme.of(context).colorScheme.primary,
                      gridColor: Theme.of(context).colorScheme.outlineVariant,
                      labelColor: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _periodButton(String period) {
    final selected = _selectedPeriod == period;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedPeriod = period;
        });
      },

      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),

        padding: EdgeInsets.symmetric(
          horizontal: MediaQuery.sizeOf(context).width < 600 ? 7 : 12,

          vertical: 8,
        ),

        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,

          borderRadius: BorderRadius.circular(9),
        ),

        child: Text(
          period,

          style: TextStyle(
            fontSize: 12,

            fontWeight: FontWeight.w700,

            color: selected
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyChart() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,

        children: [
          Icon(Icons.show_chart_rounded, size: 48, color: Colors.grey.shade300),

          const SizedBox(height: 10),

          Text(
            'No payment data for this period',

            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,

              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTodayCard(double amount, int payments) {
    return Container(
      padding: const EdgeInsets.all(22),

      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF087F6A), Color(0xFF0B927A)],
        ),

        borderRadius: BorderRadius.circular(20),

        boxShadow: [
          BoxShadow(
            color: const Color(0xFF087F6A).withOpacity(0.20),

            blurRadius: 20,

            offset: const Offset(0, 8),
          ),
        ],
      ),

      child: Row(
        children: [
          Container(
            width: 52,

            height: 52,

            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.16),

              borderRadius: BorderRadius.circular(15),
            ),

            child: const Icon(
              Icons.today_rounded,

              color: Colors.white,

              size: 28,
            ),
          ),

          const SizedBox(width: 16),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  "Today's Collection",

                  style: TextStyle(
                    color: Colors.white,

                    fontSize: 14,

                    fontWeight: FontWeight.w600,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  _formatMoney(amount),

                  style: TextStyle(
                    color: Colors.white,

                    fontSize: 25,

                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),

            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.13),

              borderRadius: BorderRadius.circular(12),
            ),

            child: Column(
              children: [
                Text(
                  payments.toString(),

                  style: TextStyle(
                    color: Colors.white,

                    fontSize: 18,

                    fontWeight: FontWeight.w800,
                  ),
                ),

                Text(
                  'Payments',

                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentActivity(List<PaymentTransaction> transactions) {
    final now = DateTime.now();

    final today = transactions.where((transaction) {
      final localDate = transaction.transactionDate.toLocal();
      return localDate.year == now.year &&
          localDate.month == now.month &&
          localDate.day == now.day;
    });

    final yesterdayDate = now.subtract(const Duration(days: 1));

    final yesterday = transactions.where((transaction) {
      final localDate = transaction.transactionDate.toLocal();
      return localDate.year == yesterdayDate.year &&
          localDate.month == yesterdayDate.month &&
          localDate.day == yesterdayDate.day;
    });

    final todayAmount = today.fold<double>(
      0,

      (sum, transaction) => sum + transaction.actualAmountReceived,
    );

    final yesterdayAmount = yesterday.fold<double>(
      0,

      (sum, transaction) => sum + transaction.actualAmountReceived,
    );

    final change = yesterdayAmount == 0
        ? null
        : ((todayAmount - yesterdayAmount) / yesterdayAmount) * 100;

    return _sectionCard(
      title: 'Payment Activity',

      subtitle: 'Today compared with yesterday',

      child: Row(
        children: [
          Expanded(
            child: _activityItem(
              'Today',

              _formatMoney(todayAmount),

              '${today.length} payments',

              Icons.today_rounded,
            ),
          ),

          Container(
            width: 1,

            height: 65,

            color: Theme.of(context).colorScheme.outlineVariant,
          ),

          Expanded(
            child: _activityItem(
              'Yesterday',

              _formatMoney(yesterdayAmount),

              '${yesterday.length} payments',

              Icons.history_rounded,
            ),
          ),

          Container(
            width: 1,

            height: 65,

            color: Theme.of(context).colorScheme.outlineVariant,
          ),

          Expanded(
            child: _activityItem(
              'Change',

              change == null
                  ? '—'
                  : '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)}%',

              'vs yesterday',

              change == null
                  ? Icons.remove_rounded
                  : change >= 0
                  ? Icons.trending_up_rounded
                  : Icons.trending_down_rounded,
            ),
          ),
        ],
      ),
    );
  }

  Widget _activityItem(
    String title,

    String value,

    String subtitle,

    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),

      child: Column(
        children: [
          Icon(icon, color: const Color(0xFF087F6A), size: 23),

          const SizedBox(height: 8),

          Text(
            value,

            style: TextStyle(
              fontSize: 18,

              fontWeight: FontWeight.w800,

              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),

          const SizedBox(height: 3),

          Text(
            subtitle,

            style: TextStyle(
              fontSize: 11,

              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopCustomers(List<_CustomerPaymentSummary> customers) {
    return _sectionCard(
      title: 'Top Customers',

      subtitle: 'Customers who have made the highest payments',

      child: customers.isEmpty
          ? _emptyMessage('No payment data available yet.')
          : Column(
              children: customers
                  .take(5)
                  .toList()
                  .asMap()
                  .entries
                  .map(
                    (entry) => _customerRankTile(
                      rank: entry.key + 1,

                      customer: entry.value,
                    ),
                  )
                  .toList(),
            ),
    );
  }

  Widget _customerRankTile({
    required int rank,

    required _CustomerPaymentSummary customer,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),

      child: Row(
        children: [
          Container(
            width: 34,

            height: 34,

            alignment: Alignment.center,

            decoration: BoxDecoration(
              color: rank == 1
                  ? (Theme.of(context).brightness == Brightness.dark
                        ? Theme.of(context).colorScheme.surfaceContainerHigh
                        : const Color(0xFFE4F5F0))
                  : Theme.of(context).colorScheme.surfaceContainerHighest,

              borderRadius: BorderRadius.circular(10),
            ),

            child: Text(
              '$rank',

              style: TextStyle(
                fontWeight: FontWeight.w800,

                color: rank == 1
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Text(
              customer.name,

              style: TextStyle(
                fontSize: 14,

                fontWeight: FontWeight.w700,

                color: Theme.of(context).colorScheme.onSurface,
              ),

              overflow: TextOverflow.ellipsis,
            ),
          ),

          Column(
            crossAxisAlignment: CrossAxisAlignment.end,

            children: [
              Text(
                _formatMoney(customer.totalPaid),

                style: TextStyle(
                  fontSize: 14,

                  fontWeight: FontWeight.w800,

                  color: Color(0xFF087F6A),
                ),
              ),

              Text(
                '${customer.paymentCount} payments',

                style: TextStyle(
                  fontSize: 10,

                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOutstandingCustomers(List<dynamic> customers) {
    return _sectionCard(
      title: 'Outstanding Customers',

      subtitle: 'Customers with money still to be collected',

      child: customers.isEmpty
          ? _emptyMessage('No outstanding balances.')
          : Column(
              children: customers.take(7).map((customer) {
                final balance = TransactionService.getCustomerBalance(
                  customer.id,
                );

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),

                  child: Row(
                    children: [
                      Container(
                        width: 40,

                        height: 40,

                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHigh
                              : const Color(0xFFFFEEE4),

                          borderRadius: BorderRadius.circular(12),
                        ),

                        child: const Icon(
                          Icons.storefront_rounded,

                          color: Color(0xFFEA580C),

                          size: 20,
                        ),
                      ),

                      const SizedBox(width: 12),

                      Expanded(
                        child: Text(
                          customer.businessName,

                          style: TextStyle(
                            fontWeight: FontWeight.w700,

                            fontSize: 14,

                            color: Theme.of(context).colorScheme.onSurface,
                          ),

                          overflow: TextOverflow.ellipsis,
                        ),
                      ),

                      Text(
                        _formatMoney(balance),

                        style: TextStyle(
                          fontWeight: FontWeight.w800,

                          fontSize: 14,

                          color: Color(0xFFEA580C),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _buildRecentPayments(List<PaymentTransaction> transactions) {
    final recent = transactions.take(8).toList();

    return _sectionCard(
      title: 'Recent Payments',

      subtitle: 'Latest payment transactions',

      child: recent.isEmpty
          ? _emptyMessage('No payments recorded yet.')
          : Column(
              children: recent
                  .map((transaction) => _recentPaymentTile(transaction))
                  .toList(),
            ),
    );
  }

  Widget _recentPaymentTile(PaymentTransaction transaction) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),

      child: Row(
        children: [
          Container(
            width: 42,

            height: 42,

            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Theme.of(context).colorScheme.surfaceContainerHigh
                  : const Color(0xFFE4F5F0),

              borderRadius: BorderRadius.circular(12),
            ),

            child: const Icon(
              Icons.arrow_downward_rounded,

              color: Color(0xFF087F6A),
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  transaction.customerName,

                  style: TextStyle(
                    fontWeight: FontWeight.w700,

                    fontSize: 14,

                    color: Theme.of(context).colorScheme.onSurface,
                  ),

                  overflow: TextOverflow.ellipsis,
                ),

                const SizedBox(height: 3),

                Text(
                  _formatDate(transaction.transactionDate),

                  style: TextStyle(
                    fontSize: 11,

                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          Text(
            '+ ${_formatMoney(transaction.actualAmountReceived)}',

            style: TextStyle(
              fontSize: 14,

              fontWeight: FontWeight.w800,

              color: Color(0xFF087F6A),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,

    required String subtitle,

    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(22),

      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,

        borderRadius: BorderRadius.circular(20),

        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),

        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.025),

            blurRadius: 16,

            offset: const Offset(0, 6),
          ),
        ],
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Text(
            title,

            style: TextStyle(
              fontSize: 19,

              fontWeight: FontWeight.w800,

              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),

          const SizedBox(height: 4),

          Text(
            subtitle,

            style: TextStyle(
              fontSize: 12,

              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 18),

          child,
        ],
      ),
    );
  }

  Widget _emptyMessage(String message) {
    return Container(
      width: double.infinity,

      padding: const EdgeInsets.symmetric(vertical: 22),

      child: Center(
        child: Text(
          message,

          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,

            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Future<void> _refreshData() async {
    if (_loading) return;

    setState(() {
      _loading = true;
    });

    await CustomerService.loadCustomers();

    await TransactionService.loadTransactions();

    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  List<_ChartPoint> _buildChartData(
    List<PaymentTransaction> transactions,

    String period,
  ) {
    final now = DateTime.now();

    if (period == '7 Days') {
      return List.generate(7, (index) {
        final date = DateTime(
          now.year,

          now.month,

          now.day,
        ).subtract(Duration(days: 6 - index));

        final total = transactions
            .where((transaction) {
              final localDate = transaction.transactionDate.toLocal();
              return localDate.year == date.year &&
                  localDate.month == date.month &&
                  localDate.day == date.day;
            })
            .fold<double>(
              0,

              (sum, transaction) => sum + transaction.actualAmountReceived,
            );

        return _ChartPoint(label: _shortDate(date), value: total);
      });
    }

    if (period == '30 Days') {
      return List.generate(30, (index) {
        final date = DateTime(
          now.year,

          now.month,

          now.day,
        ).subtract(Duration(days: 29 - index));

        final total = transactions
            .where((transaction) {
              final localDate = transaction.transactionDate.toLocal();
              return localDate.year == date.year &&
                  localDate.month == date.month &&
                  localDate.day == date.day;
            })
            .fold<double>(
              0,

              (sum, transaction) => sum + transaction.actualAmountReceived,
            );

        return _ChartPoint(label: _shortDate(date), value: total);
      });
    }

    return List.generate(12, (index) {
      final monthDate = DateTime(now.year, now.month - (11 - index), 1);

      final total = transactions
          .where((transaction) {
            final localDate = transaction.transactionDate.toLocal();
            return localDate.year == monthDate.year &&
                localDate.month == monthDate.month;
          })
          .fold<double>(
            0,

            (sum, transaction) => sum + transaction.actualAmountReceived,
          );

      return _ChartPoint(label: _shortMonth(monthDate), value: total);
    });
  }

  double _getTotalCollected(List<PaymentTransaction> transactions) {
    return transactions.fold<double>(
      0,

      (sum, transaction) => sum + transaction.actualAmountReceived,
    );
  }

  List<_CustomerPaymentSummary> _getTopCustomers(
    List<PaymentTransaction> transactions,
  ) {
    final Map<String, _CustomerPaymentSummary> summary = {};

    for (final transaction in transactions) {
      final existing = summary[transaction.customerId];

      if (existing == null) {
        summary[transaction.customerId] = _CustomerPaymentSummary(
          name: transaction.customerName,

          totalPaid: transaction.actualAmountReceived,

          paymentCount: 1,
        );
      } else {
        summary[transaction.customerId] = _CustomerPaymentSummary(
          name: existing.name,

          totalPaid: existing.totalPaid + transaction.actualAmountReceived,

          paymentCount: existing.paymentCount + 1,
        );
      }
    }

    final result = summary.values.toList();

    result.sort((a, b) => b.totalPaid.compareTo(a.totalPaid));

    return result;
  }

  String _formatMoney(double amount) {
    return CurrencyFormatter.rupees(amount);
  }

  String _shortDate(DateTime date) {
    const months = [
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
    ];

    return '${date.day} ${months[date.month - 1]}';
  }

  String _shortMonth(DateTime date) {
    const months = [
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
    ];

    return months[date.month - 1];
  }

  String _formatDate(DateTime date) {
    const months = [
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
    ];

    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;

  final String value;

  final IconData icon;

  final Color iconColor;

  final Color backgroundColor;

  const _SummaryCard({
    required this.title,

    required this.value,

    required this.icon,

    required this.iconColor,

    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),

      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,

        borderRadius: BorderRadius.circular(18),

        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),

      child: Row(
        children: [
          Container(
            width: 46,

            height: 46,

            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Theme.of(context).colorScheme.surfaceContainerHigh
                  : backgroundColor,

              borderRadius: BorderRadius.circular(13),
            ),

            child: Icon(icon, color: iconColor, size: 22),
          ),

          const SizedBox(width: 13),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  title,

                  style: TextStyle(
                    fontSize: 11,

                    color: Theme.of(context).colorScheme.onSurfaceVariant,

                    fontWeight: FontWeight.w600,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  value,

                  style: TextStyle(
                    fontSize: 18,

                    fontWeight: FontWeight.w800,

                    color: Theme.of(context).colorScheme.onSurface,
                  ),

                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartPoint {
  final String label;

  final double value;

  const _ChartPoint({required this.label, required this.value});
}

class _CustomerPaymentSummary {
  final String name;

  final double totalPaid;

  final int paymentCount;

  const _CustomerPaymentSummary({
    required this.name,

    required this.totalPaid,

    required this.paymentCount,
  });
}

class _CollectionChartPainter extends CustomPainter {
  final List<_ChartPoint> points;
  final Color lineColor;
  final Color gridColor;
  final Color labelColor;

  _CollectionChartPainter({
    required this.points,
    required this.lineColor,
    required this.gridColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    const leftPadding = 58.0;

    const rightPadding = 16.0;

    const topPadding = 18.0;

    const bottomPadding = 38.0;

    final chartWidth = size.width - leftPadding - rightPadding;

    final chartHeight = size.height - topPadding - bottomPadding;

    final maxValue = points.fold<double>(
      0,

      (max, point) => math.max(max, point.value),
    );

    final safeMax = maxValue <= 0 ? 100.0 : maxValue;

    final paintGrid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    final paintLine = Paint()
      ..color = lineColor
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final paintArea = Paint()
      ..color = lineColor.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;

    final paintDot = Paint()
      ..color = lineColor
      ..style = PaintingStyle.fill;

    final textStyle = TextStyle(
      fontSize: 10,

      color: labelColor,

      fontWeight: FontWeight.w500,
    );

    final ySteps = 4;

    for (int i = 0; i <= ySteps; i++) {
      final y = topPadding + chartHeight - (chartHeight * i / ySteps);

      canvas.drawLine(
        Offset(leftPadding, y),

        Offset(size.width - rightPadding, y),

        paintGrid,
      );

      final value = safeMax * i / ySteps;

      final label = CurrencyFormatter.rupees(value, decimals: 0);

      final textPainter = TextPainter(
        text: TextSpan(text: label, style: textStyle),

        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,

        Offset(leftPadding - textPainter.width - 9, y - textPainter.height / 2),
      );
    }

    final path = Path();

    final areaPath = Path();

    for (int i = 0; i < points.length; i++) {
      final x = points.length == 1
          ? leftPadding + chartWidth / 2
          : leftPadding + chartWidth * i / (points.length - 1);

      final y =
          topPadding + chartHeight - (points[i].value / safeMax) * chartHeight;

      if (i == 0) {
        path.moveTo(x, y);

        areaPath.moveTo(x, y);
      } else {
        path.lineTo(x, y);

        areaPath.lineTo(x, y);
      }
    }

    if (points.length > 1) {
      final lastX = leftPadding + chartWidth;

      areaPath.lineTo(lastX, topPadding + chartHeight);

      areaPath.lineTo(leftPadding, topPadding + chartHeight);

      areaPath.close();

      canvas.drawPath(areaPath, paintArea);
    }

    canvas.drawPath(path, paintLine);

    final labelEvery = points.length <= 7
        ? 1
        : points.length <= 12
        ? 2
        : 5;

    for (int i = 0; i < points.length; i += labelEvery) {
      final x = points.length == 1
          ? leftPadding + chartWidth / 2
          : leftPadding + chartWidth * i / (points.length - 1);

      final y =
          topPadding + chartHeight - (points[i].value / safeMax) * chartHeight;

      canvas.drawCircle(Offset(x, y), 4, paintDot);

      final textPainter = TextPainter(
        text: TextSpan(text: points[i].label, style: textStyle),

        textDirection: TextDirection.ltr,
      )..layout();

      final labelX = x - textPainter.width / 2;

      textPainter.paint(canvas, Offset(labelX, size.height - 25));
    }

    if (points.isNotEmpty) {
      final lastIndex = points.length - 1;

      final x = points.length == 1
          ? leftPadding + chartWidth / 2
          : leftPadding + chartWidth * lastIndex / (points.length - 1);

      final y =
          topPadding +
          chartHeight -
          (points[lastIndex].value / safeMax) * chartHeight;

      canvas.drawCircle(
        Offset(x, y),

        6,

        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill,
      );

      canvas.drawCircle(Offset(x, y), 4, paintDot);
    }
  }

  @override
  bool shouldRepaint(covariant _CollectionChartPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.labelColor != labelColor;
  }
}
